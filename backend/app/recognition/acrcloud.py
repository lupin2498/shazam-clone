"""ACRCloud identification API (primary engine).

Docs: https://docs.acrcloud.com/get-started/tutorials/recognize-music
Enable "3rd Party ID Integration" on the project so results carry ISRC/UPC and
Spotify, Deezer and YouTube ids (section 6 relies on them because YouTube and
Spotify search quotas are tiny).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import time
from typing import Any

import httpx

from .base import EngineError, EngineMatch, EngineQuotaError, TrackMeta

log = logging.getLogger(__name__)

_NO_RESULT = 1001
_QUOTA_CODES = {3003, 3015}  # limit exceeded, QPS limit exceeded


class ACRCloudClient:
    def __init__(self, http: httpx.AsyncClient, host: str, access_key: str, access_secret: str, timeout_s: float = 10.0):
        self.http = http
        self.host = host.removeprefix("https://").removeprefix("http://").rstrip("/")
        self.access_key = access_key
        self.access_secret = access_secret
        self.timeout_s = timeout_s

    def sign(self, timestamp: str) -> str:
        to_sign = "\n".join(["POST", "/v1/identify", self.access_key, "audio", "1", timestamp])
        digest = hmac.new(self.access_secret.encode(), to_sign.encode(), hashlib.sha1).digest()
        return base64.b64encode(digest).decode()

    async def identify(self, audio: bytes, filename: str) -> dict[str, Any] | None:
        ts = str(int(time.time()))
        data = {
            "access_key": self.access_key,
            "data_type": "audio",
            "signature_version": "1",
            "signature": self.sign(ts),
            "sample_bytes": str(len(audio)),
            "timestamp": ts,
        }
        try:
            resp = await self.http.post(
                f"https://{self.host}/v1/identify",
                data=data,
                files={"sample": (filename, audio, "application/octet-stream")},
                timeout=self.timeout_s,
            )
            resp.raise_for_status()
            body = resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise EngineError(f"acrcloud request failed: {exc}") from exc
        status = body.get("status") if isinstance(body, dict) else None
        if not isinstance(status, dict):
            raise EngineError("acrcloud returned an unexpected response")
        code = status.get("code")
        if code == 0:
            return body
        if code == _NO_RESULT:
            return None
        if code in _QUOTA_CODES:
            raise EngineQuotaError(f"acrcloud quota: {status.get('msg')}")
        raise EngineError(f"acrcloud status {code}: {status.get('msg')}")


def _ext(item: dict[str, Any]) -> dict[str, str]:
    ids: dict[str, str] = {}
    meta = item.get("external_metadata") or {}
    spotify = meta.get("spotify") or {}
    if isinstance(spotify, list):
        spotify = spotify[0] if spotify else {}
    if (spotify.get("track") or {}).get("id"):
        ids["spotify"] = str(spotify["track"]["id"])
    deezer = meta.get("deezer") or {}
    if isinstance(deezer, list):
        deezer = deezer[0] if deezer else {}
    if (deezer.get("track") or {}).get("id"):
        ids["deezer"] = str(deezer["track"]["id"])
    youtube = meta.get("youtube") or {}
    if isinstance(youtube, list):
        youtube = youtube[0] if youtube else {}
    if youtube.get("vid"):
        ids["youtube"] = str(youtube["vid"])
    if item.get("acrid"):
        ids["acrid"] = str(item["acrid"])
    return ids


def _artwork(item: dict[str, Any]) -> str | None:
    album = item.get("album") or {}
    covers = album.get("covers") or {}
    for key in ("large", "medium", "small"):
        if isinstance(covers, dict) and covers.get(key):
            return covers[key]
    return album.get("cover") if isinstance(album.get("cover"), str) else None


def parse_item(item: dict[str, Any], engine: str, via: str, *, percent: bool | None = None) -> EngineMatch:
    """``percent``: the score is 0-100 (fingerprints). None → guess (humming scores are 0-1 or 0-100)."""
    external = item.get("external_ids") or {}
    score = float(item.get("score") or 0)
    if percent is None:
        percent = score > 1
    confidence = score / 100.0 if percent else score
    track = TrackMeta(
        title=item.get("title") or "",
        artists=[a.get("name", "") for a in item.get("artists") or [] if a.get("name")],
        album=(item.get("album") or {}).get("name"),
        duration_ms=item.get("duration_ms"),
        isrc=(external.get("isrc") if isinstance(external.get("isrc"), str) else None),
        artwork_url=_artwork(item),
        release_date=item.get("release_date"),
        genres=[g.get("name", "") for g in item.get("genres") or [] if g.get("name")],
        external_ids=_ext(item),
    )
    return EngineMatch(track=track, confidence=round(min(max(confidence, 0.0), 1.0), 4), engine=engine, via=via)


def parse_items(body: dict[str, Any], keys: tuple[str, ...], engine: str, via: str,
                *, percent: bool | None) -> list[EngineMatch]:
    """Matches under ``metadata[key]`` for each key, best first.

    One item of an unexpected shape is skipped; an answer in which nothing can be read is an
    EngineError, so the cascade goes on to the next engine instead of the request failing
    (or, worse, reporting "no match" for an answer we could not parse).
    """
    metadata = body.get("metadata") or {}
    if not isinstance(metadata, dict):
        raise EngineError("acrcloud returned unexpected metadata")
    items: list[Any] = []
    for key in keys:
        value = metadata.get(key) or []
        if not isinstance(value, list):
            raise EngineError(f"acrcloud returned unexpected metadata.{key}")
        items.extend(value)
    matches: list[EngineMatch] = []
    skipped = 0
    for item in items:
        try:
            if item.get("title"):
                matches.append(parse_item(item, engine, via, percent=percent))
        except (AttributeError, TypeError, ValueError, KeyError, IndexError) as exc:
            skipped += 1
            log.warning("acrcloud: skipped a result of an unexpected shape: %r", exc)
    if skipped and not matches:
        raise EngineError("acrcloud returned results of an unexpected shape")
    return sorted(matches, key=lambda m: m.confidence, reverse=True)


class ACRCloudEngine:
    """Fingerprint ("music") and Cover Song / humming identification."""

    name = "acrcloud"

    def __init__(self, fingerprint: ACRCloudClient, cover: ACRCloudClient | None):
        self.fingerprint_client = fingerprint
        self.cover_client = cover

    async def fingerprint(self, audio: bytes, filename: str) -> list[EngineMatch]:
        body = await self.fingerprint_client.identify(audio, filename)
        if not body:
            return []
        # Fingerprint scores are always 0-100: a score of 1 is 1 %, not 100 %.
        return parse_items(body, ("music",), "acrcloud", "fingerprint", percent=True)

    async def cover(self, audio: bytes, filename: str) -> list[EngineMatch]:
        if not self.cover_client:
            return []
        body = await self.cover_client.identify(audio, filename)
        if not body:
            return []
        return parse_items(body, ("humming", "cover_songs"), "acrcloud_cover", "cover", percent=None)
