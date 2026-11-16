"""Per-device daily recognition quota (default 30/day, adjustable via config).

A "lượt" (one tap) may send two samples: the 6 s probe and then the 12 s sample.
Both carry the same ``session_id`` and count once. That is the *only* sharing a
session id buys: a second probe, a second full sample, or anything sent after
those two is a new tap and pays its own unit. Otherwise a client could reuse one
session id for an hour and never be counted.

When every engine fails the tap is refunded (the user got nothing for it), at
most ``limit`` times per device and day so refunds cannot be turned into an
unmetered way of calling the paid engines.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from ..cache import Cache

_SESSION_TTL_S = 3600
_DAY_TTL_S = 2 * 86400


@dataclass
class QuotaResult:
    allowed: bool
    remaining: int
    # Quota day the request was counted in (refunds go back to the same day).
    day: str = ""
    # A unit was taken from the daily count for this request (False when it rode on the
    # unit its session's probe already paid for, or when it was refused).
    charged: bool = False
    # This request opened its session (as opposed to a replay charged on its own).
    opened_session: bool = False


def quota_day(offset_hours: int, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    return (now + timedelta(hours=offset_hours)).strftime("%Y%m%d")


def _count_key(device_id: str, day: str) -> str:
    return f"quota:{device_id}:{day}"


def _session_key(device_id: str, session_id: str) -> str:
    return f"quota_session:{device_id}:{session_id}"


def _ride_key(device_id: str, session_id: str) -> str:
    return f"quota_ride:{device_id}:{session_id}"


def _served_key(device_id: str, session_id: str) -> str:
    return f"quota_served:{device_id}:{session_id}"


def _refunded_key(device_id: str, session_id: str) -> str:
    return f"quota_refunded:{device_id}:{session_id}"


async def consume(cache: Cache, *, device_id: str, session_id: str | None, limit: int,
                  stage: str = "full", offset_hours: int = 7) -> QuotaResult:
    day = quota_day(offset_hours)
    count_key = _count_key(device_id, day)
    opened = False
    if session_id:
        session_key = _session_key(device_id, session_id)
        opened = await cache.set_nx(session_key, f"pending:{stage}", _SESSION_TTL_S)
        if opened:
            # A fresh unit is about to be charged for this session: it may be refunded again.
            await cache.delete(_refunded_key(device_id, session_id))
        else:
            state = await cache.get(session_key) or ""
            if state == "denied":
                return QuotaResult(False, 0, day)
            status, _, opener_stage = state.partition(":")
            rides = (stage == "full" and opener_stage == "early"
                     and await cache.set_nx(_ride_key(device_id, session_id), "1", _SESSION_TTL_S))
            if rides:
                used = int(await cache.get(count_key) or 0)
                # While the probe is still being counted ("pending") only ride if a unit is left for it.
                if status == "ok" or used < limit:
                    return QuotaResult(True, max(limit - used, 0), day)
                return QuotaResult(False, 0, day)
            # Not the probe + full pair: a new tap that reuses the id.
    count = await cache.incr(count_key, _DAY_TTL_S)
    allowed = count <= limit
    if opened and session_id:
        await cache.set(_session_key(device_id, session_id), f"ok:{stage}" if allowed else "denied", _SESSION_TTL_S)
    return QuotaResult(allowed, max(limit - count, 0), day, charged=allowed, opened_session=opened and allowed)


async def mark_served(cache: Cache, *, device_id: str, session_id: str | None) -> None:
    """The tap got its final answer: an engine failure later in the session is not refunded."""
    if session_id:
        await cache.set(_served_key(device_id, session_id), "1", _SESSION_TTL_S)


async def refund(cache: Cache, *, device_id: str, session_id: str | None, quota: QuotaResult, limit: int) -> bool:
    """Give back the unit of a tap that ended with every engine failing. Returns whether it did."""
    if not quota.allowed:
        return False
    own_unit = quota.charged and not quota.opened_session  # no session, or a replay charged on its own
    if session_id and not own_unit:
        # The session's unit (paid by this request or by its probe): once, and only if the
        # tap has not been answered already.
        if await cache.get(_served_key(device_id, session_id)):
            return False
        if not await cache.set_nx(_refunded_key(device_id, session_id), "1", _SESSION_TTL_S):
            return False
    elif not quota.charged:
        return False
    if await cache.incr(f"quota_refunds:{device_id}:{quota.day}", _DAY_TTL_S) > limit:
        return False
    await cache.decr(_count_key(device_id, quota.day))
    if session_id and not own_unit:
        # Start over: a retry under the same id (offline queue) is charged like a first attempt.
        await cache.delete(_ride_key(device_id, session_id))
        await cache.delete(_session_key(device_id, session_id))
    return True


async def remaining(cache: Cache, *, device_id: str, limit: int, offset_hours: int = 7) -> int:
    used = int(await cache.get(_count_key(device_id, quota_day(offset_hours))) or 0)
    return max(limit - used, 0)
