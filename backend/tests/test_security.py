"""Bảo mật: khoá API không lọt vào log, link trả về app chỉ là http(s), token admin, tải lên quá cỡ."""

from __future__ import annotations

import logging

import httpx
import pytest

from tests.conftest import adts_stream, wav_bytes

YT_SEARCH = "https://www.googleapis.com/youtube/v3/search"
YT_KEY = "AIzaSyTEST-secret-youtube-key-0123456789"
JAMENDO = "https://api.jamendo.com/v3.0/tracks/"
JAMENDO_ID = "jamendo-client-id-9f8e7d6c"


async def track_id(client: httpx.AsyncClient) -> str:
    files = {"audio": ("sample.wav", wav_bytes(1.0), "audio/wav")}
    resp = await client.post("/v1/recognitions", files=files, data={"mode": "auto", "source": "mic"})
    assert resp.status_code == 200, resp.text
    return resp.json()["candidates"][0]["track"]["id"]


@pytest.mark.parametrize("status", [200, 400, 403, 500])
async def test_api_keys_never_reach_the_logs(make_client, settings, mock_http, caplog, status):
    """httpx ghi URL đầy đủ ở mức INFO và trong thông báo lỗi; URL của YouTube/Jamendo chứa khoá."""
    mock_http.get(YT_SEARCH).respond(status, json={"items": [], "error": {"message": "bad"}})
    mock_http.get(JAMENDO).respond(status, json={"results": []})
    client = await make_client(settings.model_copy(update={
        "enabled_adapters": "youtube,jamendo", "youtube_api_key": YT_KEY, "jamendo_client_id": JAMENDO_ID,
    }))
    tid = await track_id(client)
    with caplog.at_level(logging.DEBUG):
        resp = await client.get(f"/v1/tracks/{tid}/links", params={"stream": "false"})
    assert resp.status_code == 200
    assert mock_http.get(YT_SEARCH).called and mock_http.get(JAMENDO).called
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert YT_KEY not in logged
    assert JAMENDO_ID not in logged
    if status >= 400:
        # The failure itself is still reported, with the secret masked.
        assert "adapter youtube failed" in logged and "key=***" in logged


def test_redact_masks_only_secret_parameters():
    from app.logsafe import RedactSecretsFilter, redact

    url = "GET https://x.test/a?part=snippet&q=monkey+key&key=AIza123&client_id=abc#frag"
    assert redact(url) == "GET https://x.test/a?part=snippet&q=monkey+key&key=***&client_id=***#frag"
    assert redact("nothing to hide: keyboard=1 monkey=2") == "nothing to hide: keyboard=1 monkey=2"

    record = logging.LogRecord("httpx", logging.INFO, __file__, 1, "HTTP Request: %s %s", ("GET", url), None)
    assert RedactSecretsFilter().filter(record) is True
    assert "AIza123" not in record.getMessage() and "key=***" in record.getMessage()
