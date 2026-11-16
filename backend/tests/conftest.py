from __future__ import annotations

import io
import math
import struct
import wave
from collections.abc import AsyncIterator, Callable

import httpx
import pytest
import respx

from app.config import Settings
from app.main import create_app
from app.services.container import Services


def wav_bytes(seconds: float = 3.0, rate: int = 16000, freq: float = 440.0) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = b"".join(
            struct.pack("<h", int(8000 * math.sin(2 * math.pi * freq * i / rate))) for i in range(int(seconds * rate))
        )
        w.writeframes(frames)
    return buf.getvalue()


def adts_stream(seconds: float, rate_index: int = 4, rate: int = 44100, payload: int = 20) -> bytes:
    frame_len = payload + 7
    header = bytes([
        0xFF, 0xF1, (1 << 6) | (rate_index << 2), (1 << 6) | ((frame_len >> 11) & 0x3),
        (frame_len >> 3) & 0xFF, ((frame_len & 7) << 5) | 0x1F, 0xFC,
    ])
    frames = int(seconds * rate / 1024)
    return (header + b"\x00" * payload) * frames


@pytest.fixture
def settings(tmp_path) -> Settings:
    return Settings(
        _env_file=None,
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'test.db'}",
        redis_url="",
        demo_mode=True,
        integrity_mode="off",
        quota_per_device_per_day=30,
        enabled_adapters="youtube,youtube_music,spotify,deezer,zing_mp3,nct,bandcamp,cc_search",
    )


@pytest.fixture
def mock_http() -> respx.MockRouter:
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        yield router


@pytest.fixture
async def make_client(settings, mock_http) -> AsyncIterator[Callable]:
    """Build an app (optionally customised) and return an AsyncClient bound to it."""
    stack = []

    async def factory(custom_settings: Settings | None = None,
                      customize: Callable[[Services], None] | None = None) -> httpx.AsyncClient:
        app = create_app(custom_settings or settings, customize)
        lifespan = app.router.lifespan_context(app)
        await lifespan.__aenter__()
        client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test",
                                   headers={"X-Device-Id": "device-test-0001"})
        client.app = app  # type: ignore[attr-defined]
        stack.append((lifespan, client))
        return client

    yield factory
    for lifespan, client in reversed(stack):
        await client.aclose()
        await lifespan.__aexit__(None, None, None)


@pytest.fixture
async def client(make_client) -> httpx.AsyncClient:
    return await make_client()
