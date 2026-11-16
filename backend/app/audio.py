"""Validation of uploaded samples. Audio is only held in memory, never stored."""

from __future__ import annotations

import struct
from dataclasses import dataclass

_ADTS_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]


@dataclass
class SampleInfo:
    format: str  # aac | wav | m4a | mp3 | ogg | flac
    duration_s: float | None
    filename: str


class InvalidSample(ValueError):
    pass


def detect_format(data: bytes) -> str | None:
    if len(data) < 12:
        return None
    if data[0] == 0xFF and (data[1] & 0xF6) == 0xF0:
        return "aac"
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if data[4:8] == b"ftyp":
        return "m4a"
    if data[:3] == b"ID3" or (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0):
        return "mp3"
    if data[:4] == b"OggS":
        return "ogg"
    if data[:4] == b"fLaC":
        return "flac"
    return None


def adts_duration(data: bytes) -> float:
    """Duration of an ADTS AAC stream by walking frame headers (no decoding needed)."""
    pos = frames = 0
    rate = None
    while pos + 7 <= len(data):
        if data[pos] != 0xFF or (data[pos + 1] & 0xF6) != 0xF0:
            raise InvalidSample("ADTS sync lost")
        idx = (data[pos + 2] >> 2) & 0x0F
        if idx >= len(_ADTS_RATES):
            raise InvalidSample("bad ADTS sample rate")
        rate = rate or _ADTS_RATES[idx]
        frame_len = ((data[pos + 3] & 0x03) << 11) | (data[pos + 4] << 3) | (data[pos + 5] >> 5)
        if frame_len < 7:
            raise InvalidSample("bad ADTS frame length")
        frames += (data[pos + 6] & 0x03) + 1
        pos += frame_len
    if not rate or frames == 0:
        raise InvalidSample("empty ADTS stream")
    return frames * 1024 / rate


def wav_duration(data: bytes) -> float:
    pos = 12
    byte_rate = None
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if chunk_id == b"fmt " and size >= 16:
            if pos + 20 > len(data):
                raise InvalidSample("truncated WAV fmt chunk")
            byte_rate = struct.unpack("<I", data[pos + 16:pos + 20])[0]
        elif chunk_id == b"data":
            if not byte_rate:
                raise InvalidSample("WAV data before fmt")
            size = min(size, len(data) - pos - 8)
            return size / byte_rate
        pos += 8 + size + (size & 1)
    raise InvalidSample("WAV without data chunk")


def inspect_sample(data: bytes, *, max_bytes: int, max_seconds: float) -> SampleInfo:
    if not data:
        raise InvalidSample("empty sample")
    if len(data) > max_bytes:
        raise InvalidSample(f"sample larger than {max_bytes} bytes")
    fmt = detect_format(data)
    if fmt is None:
        raise InvalidSample("unsupported audio format")
    duration = None
    if fmt == "aac":
        duration = adts_duration(data)
    elif fmt == "wav":
        duration = wav_duration(data)
    if duration is not None and duration > max_seconds:
        raise InvalidSample(f"sample longer than {max_seconds:.0f} s")
    return SampleInfo(format=fmt, duration_s=duration, filename=f"sample.{fmt}")
