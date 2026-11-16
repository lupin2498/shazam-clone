"""``GET /v1/tracks/{id}/links``: links streamed per platform as Server-Sent Events."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from typing import Any, Literal

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import device_id, get_services, get_session
from ..errors import ApiError
from ..models import Track
from ..schemas import LinksOut, TrackOut
from ..services.container import Services

router = APIRouter(prefix="/v1", tags=["tracks"])


def sse(event: str, data: Any) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


async def _load(session: AsyncSession, track_id: str) -> Track:
    track = await session.get(Track, track_id)
    if track is None:
        raise ApiError(404, "not_found", "Không tìm thấy bài hát.")
    return track


@router.get("/tracks/{track_id}", response_model=TrackOut)
async def get_track(track_id: str, session: AsyncSession = Depends(get_session)) -> TrackOut:
    return TrackOut.of(await _load(session, track_id))


@router.get("/tracks/{track_id}/links", response_model=LinksOut,
            responses={200: {"content": {"text/event-stream": {}}}})
async def track_links(
    request: Request,
    track_id: str,
    country: str = Query("VN", pattern="^[A-Za-z]{2}$"),
    variant: Literal["beat"] | None = Query(None, description="beat: add beat/karaoke/instrumental searches"),
    stream: bool = Query(True, description="false → one JSON response once every adapter is done"),
    _device: str = Depends(device_id),
    services: Services = Depends(get_services),
):
    # Not the request-scoped session: it would stay checked out for the whole stream.
    async with services.db.sessionmaker() as session:
        track = await _load(session, track_id)
    country = country.upper()
    if not stream:
        links = await services.resolver.resolve_all(track, country, variant)
        return LinksOut(track=TrackOut.of(track), links=links)

    track_out = TrackOut.of(track).model_dump()

    async def events() -> AsyncIterator[str]:
        yield sse("track", track_out)
        count = 0
        async for event in services.resolver.stream(track, country, variant):
            count += len(event.links)
            yield sse("links", {"adapter": event.adapter, "links": event.links,
                                "cached": event.cached, "degraded": event.degraded})
            if await request.is_disconnected():
                return
        yield sse("done", {"count": count})

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
