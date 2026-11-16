"""Small cache/counter abstraction over Redis (production) or process memory (dev/tests)."""

from __future__ import annotations

import json
import time
from typing import Any, Protocol


class Cache(Protocol):
    async def get_json(self, key: str) -> Any | None: ...
    async def set_json(self, key: str, value: Any, ttl_s: int) -> None: ...
    async def get(self, key: str) -> str | None: ...
    async def set(self, key: str, value: str, ttl_s: int) -> None: ...
    async def set_nx(self, key: str, value: str, ttl_s: int) -> bool: ...
    async def incr(self, key: str, ttl_s: int) -> int: ...
    async def decr(self, key: str) -> int: ...
    async def delete(self, key: str) -> None: ...
    async def close(self) -> None: ...


class MemoryCache:
    def __init__(self) -> None:
        self._data: dict[str, tuple[str, float]] = {}

    def _alive(self, key: str) -> str | None:
        item = self._data.get(key)
        if item is None:
            return None
        value, expires = item
        if expires and expires < time.monotonic():
            self._data.pop(key, None)
            return None
        return value

    async def get(self, key: str) -> str | None:
        return self._alive(key)

    async def set(self, key: str, value: str, ttl_s: int) -> None:
        self._data[key] = (value, time.monotonic() + ttl_s if ttl_s else 0)

    async def get_json(self, key: str) -> Any | None:
        raw = self._alive(key)
        return None if raw is None else json.loads(raw)

    async def set_json(self, key: str, value: Any, ttl_s: int) -> None:
        await self.set(key, json.dumps(value), ttl_s)

    async def set_nx(self, key: str, value: str, ttl_s: int) -> bool:
        if self._alive(key) is not None:
            return False
        await self.set(key, value, ttl_s)
        return True

    async def incr(self, key: str, ttl_s: int) -> int:
        current = self._alive(key)
        if current is None:
            await self.set(key, "1", ttl_s)
            return 1
        value = int(current) + 1
        expires = self._data[key][1]
        self._data[key] = (str(value), expires)
        return value

    async def decr(self, key: str) -> int:
        """Decrement a counter, never below zero and without touching its expiry."""
        current = self._alive(key)
        if current is None or int(current) <= 0:
            return 0
        value = int(current) - 1
        self._data[key] = (str(value), self._data[key][1])
        return value

    async def delete(self, key: str) -> None:
        self._data.pop(key, None)

    async def close(self) -> None:
        self._data.clear()


_DECR_FLOOR = """
local v = tonumber(redis.call('GET', KEYS[1]) or '0')
if v <= 0 then return 0 end
return redis.call('DECR', KEYS[1])
"""


class RedisCache:
    def __init__(self, url: str) -> None:
        import redis.asyncio as redis

        self._r = redis.from_url(url, decode_responses=True)

    async def get(self, key: str) -> str | None:
        return await self._r.get(key)

    async def set(self, key: str, value: str, ttl_s: int) -> None:
        await self._r.set(key, value, ex=ttl_s or None)

    async def get_json(self, key: str) -> Any | None:
        raw = await self._r.get(key)
        return None if raw is None else json.loads(raw)

    async def set_json(self, key: str, value: Any, ttl_s: int) -> None:
        await self._r.set(key, json.dumps(value), ex=ttl_s or None)

    async def set_nx(self, key: str, value: str, ttl_s: int) -> bool:
        return bool(await self._r.set(key, value, ex=ttl_s or None, nx=True))

    async def incr(self, key: str, ttl_s: int) -> int:
        pipe = self._r.pipeline()
        pipe.incr(key)
        pipe.expire(key, ttl_s, nx=True)
        value, _ = await pipe.execute()
        return int(value)

    async def decr(self, key: str) -> int:
        # One round trip, atomic on the server: a missing or zero counter stays as it is
        # (a bare DECR would create "-1" with no expiry).
        return int(await self._r.eval(_DECR_FLOOR, 1, key))

    async def delete(self, key: str) -> None:
        await self._r.delete(key)

    async def close(self) -> None:
        await self._r.aclose()


def make_cache(redis_url: str) -> Cache:
    return RedisCache(redis_url) if redis_url else MemoryCache()
