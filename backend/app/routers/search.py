"""``GET /v1/search?q=``: manual search by name when recognition does not match."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Header, Query
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import check_app_version, device_id, get_services, get_session, require_integrity
from ..errors import ApiError
from ..schemas import SearchOut, TrackOut
from ..security.integrity import request_hash
from ..services.container import Services
from ..services.tracks import upsert_track

router = APIRouter(prefix="/v1", tags=["search"])


@router.get("/search", response_model=SearchOut, dependencies=[Depends(check_app_version)])
async def search(
    q: str = Query(..., min_length=2, max_length=200),
    country: str = Query("VN", pattern="^[A-Za-z]{2}$"),
    limit: int = Query(10, ge=1, le=20),
    device: str = Depends(device_id),
    x_integrity_token: str | None = Header(default=None),
    services: Services = Depends(get_services),
    session: AsyncSession = Depends(get_session),
) -> SearchOut:
    settings = services.settings
    await require_integrity(services, x_integrity_token, request_hash(device, "search", q))
    day = (datetime.now(timezone.utc) + timedelta(hours=settings.quota_timezone_offset_hours)).strftime("%Y%m%d")
    if await services.cache.incr(f"search_quota:{device}:{day}", 2 * 86400) > settings.search_per_device_per_day:
        raise ApiError(429, "quota_exceeded", "Bạn đã tìm kiếm quá nhiều lần hôm nay.")
    metas = await services.catalog.search(q.strip(), country.upper(), limit)
    tracks = []
    seen: set[str] = set()
    for meta in metas:
        track = await upsert_track(session, meta)
        if track.id not in seen:
            seen.add(track.id)
            tracks.append(track)
    await session.commit()
    return SearchOut(results=[TrackOut.of(t) for t in tracks])
