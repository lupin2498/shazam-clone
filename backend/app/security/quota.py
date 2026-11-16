"""Per-device daily recognition quota (default 30/day, adjustable via config).

A "lượt" (one tap) may send two samples (the 6 s probe and the 12 s sample);
both share a ``session_id`` and count once.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from ..cache import Cache


@dataclass
class QuotaResult:
    allowed: bool
    remaining: int


def quota_day(offset_hours: int, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    return (now + timedelta(hours=offset_hours)).strftime("%Y%m%d")


async def consume(cache: Cache, *, device_id: str, session_id: str | None, limit: int, offset_hours: int = 7) -> QuotaResult:
    count_key = f"quota:{device_id}:{quota_day(offset_hours)}"
    if session_id:
        session_key = f"quota_session:{device_id}:{session_id}"
        claimed = await cache.set_nx(session_key, "pending", 3600)
        if not claimed:
            state = await cache.get(session_key)
            used = int(await cache.get(count_key) or 0)
            if state == "denied":
                return QuotaResult(False, 0)
            return QuotaResult(True, max(limit - used, 0))
    count = await cache.incr(count_key, 2 * 86400)
    allowed = count <= limit
    if session_id:
        await cache.set(f"quota_session:{device_id}:{session_id}", "ok" if allowed else "denied", 3600)
    return QuotaResult(allowed, max(limit - count, 0))


async def remaining(cache: Cache, *, device_id: str, limit: int, offset_hours: int = 7) -> int:
    used = int(await cache.get(f"quota:{device_id}:{quota_day(offset_hours)}") or 0)
    return max(limit - used, 0)
