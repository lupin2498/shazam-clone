"""Prefixed, time-sortable identifiers such as ``rec_01hzx...`` and ``trk_...``."""

from __future__ import annotations

import os
import time

_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"  # Crockford base32, lower case


def new_id(prefix: str) -> str:
    """Return ``<prefix>_<26 chars>``: 48-bit millisecond timestamp + 80 random bits (ULID layout)."""
    value = (int(time.time() * 1000) << 80) | int.from_bytes(os.urandom(10), "big")
    chars = []
    for _ in range(26):
        chars.append(_ALPHABET[value & 31])
        value >>= 5
    return f"{prefix}_{''.join(reversed(chars))}"
