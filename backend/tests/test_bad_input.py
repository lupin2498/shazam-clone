"""Dữ liệu xấu từ client (mẫu âm thanh cụt, header lạ) phải thành 4xx, không thành lỗi 500."""

from __future__ import annotations

import struct

import pytest

from app.audio import InvalidSample, inspect_sample
from tests.conftest import adts_stream


# --- uploaded samples ---------------------------------------------------------

@pytest.mark.parametrize("data", [
    b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00",          # fmt chunk cut after 2 bytes
    b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00" + b"\x00" * 9,     # byte rate field missing
    b"RIFF\x24\x00\x00\x00WAVE" + b"data" + struct.pack("<I", 100),   # data before fmt
    b"RIFF\x24\x00\x00\x00WAVEfmt " + struct.pack("<I", 0xFFFFFFFF),   # absurd chunk size
])
def test_truncated_wav_is_an_invalid_sample_not_a_crash(data):
    with pytest.raises(InvalidSample):
        inspect_sample(data, max_bytes=2_000_000, max_seconds=15.5)


async def test_truncated_wav_upload_is_422(client):
    resp = await client.post("/v1/recognitions", files={
        "audio": ("s.wav", b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00", "audio/wav")})
    assert resp.status_code == 422 and resp.json()["error"] == "invalid_sample"


# --- request headers ------------------------------------------------------------

async def test_non_ascii_admin_token_is_unauthorised_not_a_crash(make_client, settings):
    client = await make_client(settings.model_copy(update={"admin_token": "s3cret"}))
    resp = await client.get("/admin/reports", headers={"X-Admin-Token": "sécret".encode("latin-1")})
    assert resp.status_code == 401
    assert (await client.get("/admin/reports", headers={"X-Admin-Token": "s3cret"})).status_code == 200


@pytest.mark.parametrize("version,status", [("1.0", 200), ("1", 200), ("1.0.0", 200), ("1.0.1", 200),
                                             ("0.9", 426), ("0.9.9", 426), ("v1.0.0+7", 200)])
async def test_app_version_gate_pads_short_versions(client, version, status):
    """"1.0" không được coi là cũ hơn "1.0.0" (app và backend phải so phiên bản như nhau)."""
    resp = await client.post("/v1/recognitions", files={"audio": ("s.aac", adts_stream(5), "audio/aac")},
                             headers={"X-App-Version": version})
    assert resp.status_code == status, resp.text
