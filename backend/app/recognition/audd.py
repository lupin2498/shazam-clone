"""AudD recognition API (fallback engine). Docs: https://docs.audd.io/"""

from __future__ import annotations

from typing import Any

import httpx

from .base import EngineError, EngineMatch, EngineQuotaError, TrackMeta, split_artists

_QUOTA_ERRORS = {901, 902}


def _obj(value: Any) -> dict[str, Any]:
    """Optional sub-object of the answer: anything that is not an object counts as absent."""
    return value if isinstance(value, dict) else {}


def _int(value: Any) -> int | None:
    try:
        return int(value) if value else None
    except (TypeError, ValueError):
        return None


def _apple_artwork(apple: dict[str, Any]) -> str | None:
    url = _obj(apple.get("artwork")).get("url")
    return url.replace("{w}", "600").replace("{h}", "600") if isinstance(url, str) and url else None


def _artists(res: dict[str, Any], spotify: dict[str, Any]) -> list[str]:
    # Spotify's structured list is exact; the free-text "artist" field has to be guessed apart
    # ("Tyler, The Creator" is one artist, "Imagine Dragons, JID" is two).
    listed = spotify.get("artists")
    if isinstance(listed, list):
        names = [a["name"].strip() for a in listed
                 if isinstance(a, dict) and isinstance(a.get("name"), str) and a["name"].strip()]
        if names:
            return names
    return split_artists(res.get("artist"))


def parse_result(res: dict[str, Any], confidence: float) -> EngineMatch:
    apple = _obj(res.get("apple_music"))
    spotify = _obj(res.get("spotify"))
    deezer = _obj(res.get("deezer"))
    isrc = apple.get("isrc") or _obj(spotify.get("external_ids")).get("isrc") or deezer.get("isrc")
    duration = _int(spotify.get("duration_ms")) or _int(apple.get("durationInMillis"))
    if not duration and _int(deezer.get("duration")):
        duration = _int(deezer.get("duration")) * 1000
    artwork = _apple_artwork(apple)
    if not artwork:
        images = _obj(spotify.get("album")).get("images")
        first = images[0] if isinstance(images, list) and images else None
        artwork = _obj(first).get("url") or _obj(deezer.get("album")).get("cover_xl")
    ids: dict[str, str] = {}
    if spotify.get("id"):
        ids["spotify"] = str(spotify["id"])
    if deezer.get("id"):
        ids["deezer"] = str(deezer["id"])
    if isinstance(apple.get("url"), str) and apple["url"]:
        ids["apple_music_url"] = apple["url"]
    if isinstance(res.get("song_link"), str) and res["song_link"]:
        ids["song_link"] = res["song_link"]
    genres = apple.get("genreNames")
    track = TrackMeta(
        title=str(res.get("title") or ""),
        artists=_artists(res, spotify),
        album=res.get("album") if isinstance(res.get("album"), str) else None,
        duration_ms=duration,
        isrc=isrc if isinstance(isrc, str) else None,
        artwork_url=artwork if isinstance(artwork, str) else None,
        release_date=res.get("release_date") if isinstance(res.get("release_date"), str) else None,
        genres=[g for g in genres if isinstance(g, str)] if isinstance(genres, list) else [],
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
        if not isinstance(body, dict):
            raise EngineError("audd returned an unexpected response")
        if body.get("status") == "error":
            err = _obj(body.get("error"))
            if err.get("error_code") in _QUOTA_ERRORS:
                raise EngineQuotaError(f"audd quota: {err.get('error_message')}")
            raise EngineError(f"audd error {err.get('error_code')}: {err.get('error_message') or body.get('error')}")
        result = body.get("result")
        if not result:
            return []
        if not isinstance(result, dict):
            raise EngineError("audd returned an unexpected result")
        if not result.get("title"):
            return []
        return [parse_result(result, self.confidence)]
