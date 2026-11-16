"""AudD recognition API (fallback engine). Docs: https://docs.audd.io/"""

from __future__ import annotations

from typing import Any

import httpx

from .base import EngineError, EngineMatch, EngineQuotaError, TrackMeta, split_artists

_QUOTA_ERRORS = {901, 902}


def _apple_artwork(apple: dict[str, Any]) -> str | None:
    url = (apple.get("artwork") or {}).get("url")
    return url.replace("{w}", "600").replace("{h}", "600") if url else None


def parse_result(res: dict[str, Any], confidence: float) -> EngineMatch:
    apple = res.get("apple_music") or {}
    spotify = res.get("spotify") or {}
    deezer = res.get("deezer") or {}
    isrc = apple.get("isrc") or (spotify.get("external_ids") or {}).get("isrc") or deezer.get("isrc")
    duration = spotify.get("duration_ms") or apple.get("durationInMillis")
    if not duration and deezer.get("duration"):
        duration = int(deezer["duration"]) * 1000
    artwork = _apple_artwork(apple)
    if not artwork:
        images = (spotify.get("album") or {}).get("images") or []
        artwork = images[0]["url"] if images else (deezer.get("album") or {}).get("cover_xl")
    ids: dict[str, str] = {}
    if spotify.get("id"):
        ids["spotify"] = str(spotify["id"])
    if deezer.get("id"):
        ids["deezer"] = str(deezer["id"])
    if apple.get("url"):
        ids["apple_music_url"] = apple["url"]
    if res.get("song_link"):
        ids["song_link"] = res["song_link"]
    track = TrackMeta(
        title=res.get("title") or "",
        artists=split_artists(res.get("artist")),
        album=res.get("album"),
        duration_ms=int(duration) if duration else None,
        isrc=isrc,
        artwork_url=artwork,
        release_date=res.get("release_date"),
        genres=list(apple.get("genreNames") or []),
        external_ids=ids,
    )
    return EngineMatch(track=track, confidence=confidence, engine="audd", via="fingerprint")


class AudDEngine:
    name = "audd"

    def __init__(self, http: httpx.AsyncClient, api_token: str, confidence: float = 0.9, timeout_s: float = 15.0):
        self.http = http
        self.api_token = api_token
        self.confidence = confidence
        self.timeout_s = timeout_s

    async def identify(self, audio: bytes, filename: str) -> list[EngineMatch]:
        try:
            resp = await self.http.post(
                "https://api.audd.io/",
                data={"api_token": self.api_token, "return": "apple_music,spotify,deezer"},
                files={"file": (filename, audio, "application/octet-stream")},
                timeout=self.timeout_s,
            )
            resp.raise_for_status()
            body = resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise EngineError(f"audd request failed: {exc}") from exc
        if body.get("status") == "error":
            err = body.get("error") or {}
            if err.get("error_code") in _QUOTA_ERRORS:
                raise EngineQuotaError(f"audd quota: {err.get('error_message')}")
            raise EngineError(f"audd error {err.get('error_code')}: {err.get('error_message')}")
        result = body.get("result")
        if not result or not result.get("title"):
            return []
        return [parse_result(result, self.confidence)]
