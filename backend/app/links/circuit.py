"""Per-adapter circuit breaker: one failing platform must not slow down the others (section 10)."""

from __future__ import annotations

import time


class CircuitBreaker:
    def __init__(self, threshold: int, reset_s: float):
        self.threshold = threshold
        self.reset_s = reset_s
        self.failures = 0
        self.opened_at: float | None = None

    def allow(self) -> bool:
        if self.opened_at is None:
            return True
        if time.monotonic() - self.opened_at >= self.reset_s:
            # Half-open: let one call through; a failure re-opens immediately.
            self.opened_at = None
            self.failures = self.threshold - 1
            return True
        return False

    def success(self) -> None:
        self.failures = 0
        self.opened_at = None

    def failure(self) -> None:
        self.failures += 1
        if self.failures >= self.threshold:
            self.opened_at = time.monotonic()

    @property
    def is_open(self) -> bool:
        return self.opened_at is not None


class BreakerRegistry:
    def __init__(self, threshold: int, reset_s: float):
        self.threshold = threshold
        self.reset_s = reset_s
        self._breakers: dict[str, CircuitBreaker] = {}

    def get(self, name: str) -> CircuitBreaker:
        if name not in self._breakers:
            self._breakers[name] = CircuitBreaker(self.threshold, self.reset_s)
        return self._breakers[name]
