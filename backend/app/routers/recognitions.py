"""``POST /v1/recognitions``: receive a sample, run the engine cascade, return the match or candidates."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Literal

from fastapi import APIRouter, Depends, File, Form, Header, Response, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from ..audio import InvalidSample, inspect_sample
from ..deps import check_app_version, device_id, get_services, get_session, require_integrity
from ..errors import ApiError
from ..ids import new_id
from ..models import Candidate, Recognition, RecognitionReport
from ..recognition.cascade import EnginesUnavailable, candidate_flags
from ..schemas import CandidateOut, RecognitionOut, RecognitionReportIn, TrackOut
from ..security.integrity import request_hash, sha256_hex
from ..security.quota import consume, mark_served, refund
from ..services.container import Services
from ..services.tracks import lock_tracks, upsert_track

log = logging.getLogger(__name__)
router = APIRouter(prefix="/v1", tags=["recognitions"])


@router.post("/recognitions", response_model=RecognitionOut, dependencies=[Depends(check_app_version)])
async def create_recognition(
    response: Response,
    audio: UploadFile = File(..., description="AAC (ADTS) sample, at most 15 s"),
    mode: Literal["auto", "hum"] = Form("auto"),
    # playback: audio of another app on the phone, captured on Android 10+ (AudioPlaybackCapture).
    source: Literal["mic", "file", "hum", "playback"] = Form("mic"),
    stage: Literal["early", "full"] = Form("full"),
    session_id: str | None = Form(None, max_length=64),
    filename_hint: str | None = Form(None, max_length=200),
    device: str = Depends(device_id),
    x_integrity_token: str | None = Header(default=None),
    services: Services = Depends(get_services),
    session: AsyncSession = Depends(get_session),
) -> RecognitionOut:
    started = time.perf_counter()
    settings = services.settings
    if not services.cascade.available:
        raise ApiError(503, "no_engine", "Dịch vụ nhận diện chưa được cấu hình.")

    data = await audio.read(settings.max_upload_bytes + 1)
    try:
        info = inspect_sample(data, max_bytes=settings.max_upload_bytes, max_seconds=settings.max_sample_seconds)
    except InvalidSample as exc:
        raise ApiError(422, "invalid_sample", "Mẫu âm thanh không hợp lệ.", detail=str(exc)) from exc
    if source == "hum":
        mode = "hum"
    if mode == "hum":
        stage = "full"

    await require_integrity(services, x_integrity_token,
                            request_hash(device, session_id or "", stage, sha256_hex(data)))
    quota = await consume(services.cache, device_id=device, session_id=session_id, stage=stage,
                          limit=settings.quota_per_device_per_day, offset_hours=settings.quota_timezone_offset_hours)
    if not quota.allowed:
        raise ApiError(429, "quota_exceeded",
                       f"Bạn đã dùng hết {settings.quota_per_device_per_day} lượt nhận diện hôm nay. Hãy thử lại vào ngày mai.",
                       headers={"X-Quota-Remaining": "0"})

    rec = Recognition(id=new_id("rec"), device_id=device, session_id=session_id, source=source, mode=mode,
                      stage=stage, status="no_match")
    try:
        outcome = await services.cascade.run(data, info.filename, mode=mode, stage=stage)
    except Exception as exc:  # noqa: BLE001 - an engine bug must not cost the user a tap either
        if not isinstance(exc, EnginesUnavailable):
            log.exception("recognition cascade crashed")
        # The user got nothing for this tap: give the unit back (bounded per day, see quota.py).
        refunded = await refund(services.cache, device_id=device, session_id=session_id, quota=quota,
                                limit=settings.quota_per_device_per_day)
        rec.status, rec.error = "error", (str(exc) or type(exc).__name__)[:1000]
        rec.latency_ms = int((time.perf_counter() - started) * 1000)
        session.add(rec)
        await session.commit()
        log.warning("recognition %s failed (%s), quota refunded=%s", rec.id, type(exc).__name__, refunded)
        raise ApiError(503, "engines_unavailable", "Máy chủ nhận diện đang bận, vui lòng thử lại sau.") from exc
    finally:
        del data  # the sample is never stored (section 10, privacy)
    if outcome.final:
        await mark_served(services.cache, device_id=device, session_id=session_id)

    await asyncio.gather(*(services.catalog.enrich(m.track, settings.artwork_lookup_timeout_s)
                           for m in outcome.matches))
    flags = candidate_flags(outcome, mode=mode, filename_hint=filename_hint)

    rec.status, rec.engine = outcome.status, outcome.engine
    rec.error = "; ".join(outcome.errors)[:1000] or None
    session.add(rec)
    await session.flush()
    candidates: list[CandidateOut] = []
    await lock_tracks(session, [m.track for m in outcome.matches])
    for rank, (match, match_flags) in enumerate(zip(outcome.matches, flags), start=1):
        track = await upsert_track(session, match.track)
        session.add(Candidate(recognition_id=rec.id, track_id=track.id, confidence=match.confidence,
                              rank=rank, flags=match_flags))
        candidates.append(CandidateOut(track=TrackOut.of(track), confidence=match.confidence, rank=rank,
                                       flags=match_flags))
    if candidates:
        rec.top_track_id = candidates[0].track.id
        rec.confidence = candidates[0].confidence
    rec.latency_ms = int((time.perf_counter() - started) * 1000)
    await session.commit()

    log.info("recognition %s source=%s mode=%s stage=%s status=%s engine=%s %dms",
             rec.id, source, mode, stage, rec.status, rec.engine, rec.latency_ms)
    response.headers["X-Quota-Remaining"] = str(quota.remaining)
    return RecognitionOut(
        id=rec.id, status=outcome.status, engine=outcome.engine, stage=stage, final=outcome.final,
        candidates=candidates, latency_ms=rec.latency_ms, quota_remaining=quota.remaining,
    )


@router.post("/recognitions/{recognition_id}/report", status_code=202)
async def report_recognition(
    recognition_id: str,
    body: RecognitionReportIn,
    device: str = Depends(device_id),
    session: AsyncSession = Depends(get_session),
) -> dict[str, bool]:
    """"Báo sai" on the result screen; feeds the accuracy numbers in section 10."""
    rec = await session.get(Recognition, recognition_id)
    if rec is None or rec.device_id != device:
        raise ApiError(404, "not_found", "Không tìm thấy lượt nhận diện.")
    session.add(RecognitionReport(recognition_id=rec.id, device_id=device, reason=body.reason, note=body.note))
    await session.commit()
    return {"ok": True}
