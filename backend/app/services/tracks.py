"""Track persistence: one row per recording, de-duplicated by ISRC then by normalised name."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..ids import new_id
from ..models import Track
from ..recognition.base import TrackMeta
from ..text import infer_instrumental, is_classical, match_key


async def upsert_track(session: AsyncSession, meta: TrackMeta) -> Track:
    isrc = (meta.isrc or "").strip().upper() or None
    key = match_key(meta.title, meta.artists)
    track: Track | None = None
    if isrc:
        track = (await session.execute(select(Track).where(Track.isrc == isrc))).scalar_one_or_none()
    if track is None:
        stmt = select(Track).where(Track.match_key == key)
        if isrc:
            stmt = stmt.where(Track.isrc.is_(None))
        track = (await session.execute(stmt.limit(1))).scalar_one_or_none()

    instrumental = infer_instrumental(meta.title, meta.genres, meta.album)
    work_title = meta.title if is_classical(meta.title, meta.genres) else None

    if track is None:
        track = Track(
            id=new_id("trk"),
            isrc=isrc,
            match_key=key,
            title=meta.title,
            artists=list(meta.artists),
            album=meta.album,
            duration_ms=meta.duration_ms,
            artwork_url=meta.artwork_url,
            is_instrumental=instrumental,
            work_title=work_title,
            genres=list(meta.genres),
            release_date=meta.release_date,
            external_ids=dict(meta.external_ids),
        )
        session.add(track)
    else:
        # Fill gaps; never overwrite good data with empty values.
        track.isrc = track.isrc or isrc
        track.album = track.album or meta.album
        track.duration_ms = track.duration_ms or meta.duration_ms
        track.artwork_url = track.artwork_url or meta.artwork_url
        track.release_date = track.release_date or meta.release_date
        track.work_title = track.work_title or work_title
        track.is_instrumental = track.is_instrumental or instrumental
        if meta.genres and not track.genres:
            track.genres = list(meta.genres)
        if meta.external_ids:
            track.external_ids = {**meta.external_ids, **(track.external_ids or {})}
    await session.flush()
    return track
