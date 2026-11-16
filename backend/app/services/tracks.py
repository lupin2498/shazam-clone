"""Track persistence: one row per recording, de-duplicated by ISRC then by normalised name."""

from __future__ import annotations

import re

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import insert_if_absent
from ..ids import new_id
from ..links.base import safe_link_url
from ..models import Track
from ..recognition.base import TrackMeta
from ..text import infer_instrumental, is_classical, match_key

_ISRC = re.compile(r"[A-Z]{2}[A-Z0-9]{3}[0-9]{7}")
_ISRC_SEPARATORS = re.compile(r"[\s\-_.]")


def normalize_isrc(raw: object) -> str | None:
    """``us-rc1-76-07839`` → ``USRC17607839``; anything that is not an ISRC → None.

    The ISRC is a unique key, part of cache keys and pasted into the Deezer lookup URL, and
    the column is 16 characters wide: an engine answering with something else must not
    break any of those.
    """
    if not isinstance(raw, str):
        return None
    value = _ISRC_SEPARATORS.sub("", raw).upper()
    return value if _ISRC.fullmatch(value) else None


def positive_int32(value: object) -> int | None:
    """Durations go into 32-bit INTEGER columns; drop what does not fit instead of failing the insert."""
    try:
        number = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError, OverflowError):
        return None
    return number if 0 < number < 2 ** 31 else None


def _short(value: object, limit: int) -> str | None:
    return str(value)[:limit] if value else None


async def upsert_track(session: AsyncSession, meta: TrackMeta) -> Track:
    isrc = normalize_isrc(meta.isrc)
    key = match_key(meta.title, meta.artists)
    duration_ms = positive_int32(meta.duration_ms)
    artwork_url = safe_link_url(meta.artwork_url)
    release_date = _short(meta.release_date, 32)
    instrumental = infer_instrumental(meta.title, meta.genres, meta.album)
    work_title = meta.title if is_classical(meta.title, meta.genres) else None

    track: Track | None = None
    created = False
    if isrc:
        track = (await session.execute(select(Track).where(Track.isrc == isrc))).scalar_one_or_none()
    if track is None:
        stmt = select(Track).where(Track.match_key == key)
        if isrc:
            stmt = stmt.where(Track.isrc.is_(None))
        # Oldest first: if a race ever stored the same name twice, everyone agrees on one row.
        track = (await session.execute(stmt.order_by(Track.created_at, Track.id).limit(1))).scalar_one_or_none()

    if track is None:
        values = dict(
            id=new_id("trk"),
            isrc=isrc,
            match_key=key,
            title=meta.title,
            artists=list(meta.artists),
            album=meta.album,
            duration_ms=duration_ms,
            artwork_url=artwork_url,
            is_instrumental=instrumental,
            work_title=work_title,
            genres=list(meta.genres),
            release_date=release_date,
            external_ids=dict(meta.external_ids),
        )
        if isrc:
            # Another request may be storing the same recording right now (UNIQUE on isrc).
            created = await insert_if_absent(session, Track, values, ["isrc"])
            track = (await session.execute(select(Track).where(Track.isrc == isrc))).scalar_one()
        else:
            track = Track(**values)
            session.add(track)
            created = True
    if not created:
        # Fill gaps; never overwrite good data with empty values.
        track.isrc = track.isrc or isrc
        track.album = track.album or meta.album
        track.duration_ms = track.duration_ms or duration_ms
        track.artwork_url = track.artwork_url or artwork_url
        track.release_date = track.release_date or release_date
        track.work_title = track.work_title or work_title
        track.is_instrumental = track.is_instrumental or instrumental
        if meta.genres and not track.genres:
            track.genres = list(meta.genres)
        if meta.external_ids:
            track.external_ids = {**meta.external_ids, **(track.external_ids or {})}
    await session.flush()
    return track
