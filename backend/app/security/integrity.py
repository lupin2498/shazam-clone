"""Play Integrity verification (sections 4, 8, 10).

The app requests a *standard* integrity token whose ``requestHash`` binds it to
the request (device, session, stage and the SHA-256 of the audio). The backend
decodes the token with Google's ``decodeIntegrityToken`` endpoint and checks
package name, request hash, freshness, app and device verdicts before any paid
engine is called.

Modes: ``off`` (development), ``monitor`` (verify and log, never block) and
``enforce`` (reject with 403).
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from dataclasses import dataclass
from typing import Any

import httpx

from ..config import Settings

log = logging.getLogger(__name__)

_SCOPE = "https://www.googleapis.com/auth/playintegrity"


def sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode()
    return hashlib.sha256(data).hexdigest()


def request_hash(device_id: str, *parts: str) -> str:
    """Hash the app puts in the token request; mirrored in the app (lib/services/integrity.dart)."""
    return sha256_hex("|".join([device_id, *parts]))


@dataclass
class IntegrityVerdict:
    ok: bool
    reason: str = ""


class IntegrityVerifier:
    def __init__(self, settings: Settings, http: httpx.AsyncClient):
        self.settings = settings
        self.http = http
        self._credentials: Any = None
        self._lock = asyncio.Lock()

    @property
    def mode(self) -> str:
        return self.settings.integrity_mode.lower()

    async def _access_token(self) -> str:
        async with self._lock:
            if self._credentials is None:
                from google.oauth2 import service_account

                self._credentials = service_account.Credentials.from_service_account_file(
                    self.settings.google_service_account_file, scopes=[_SCOPE]
                )
            if not self._credentials.valid:
                from google.auth.transport.requests import Request

                await asyncio.to_thread(self._credentials.refresh, Request())
            return self._credentials.token

    async def decode(self, token: str) -> dict[str, Any]:
        package = self.settings.play_package_name
        resp = await self.http.post(
            f"https://playintegrity.googleapis.com/v1/{package}:decodeIntegrityToken",
            json={"integrity_token": token},
            headers={"Authorization": f"Bearer {await self._access_token()}"},
            timeout=5.0,
        )
        resp.raise_for_status()
        return resp.json().get("tokenPayloadExternal") or {}

    def check_payload(self, payload: dict[str, Any], expected_hash: str) -> IntegrityVerdict:
        details = payload.get("requestDetails") or {}
        if details.get("requestPackageName") != self.settings.play_package_name:
            return IntegrityVerdict(False, "package_mismatch")
        if details.get("requestHash") != expected_hash:
            return IntegrityVerdict(False, "request_hash_mismatch")
        ts = int(details.get("timestampMillis") or 0)
        if abs(time.time() * 1000 - ts) > self.settings.integrity_max_age_s * 1000:
            return IntegrityVerdict(False, "stale_token")
        app = (payload.get("appIntegrity") or {}).get("appRecognitionVerdict")
        if app != "PLAY_RECOGNIZED":
            return IntegrityVerdict(False, f"app_{(app or 'unknown').lower()}")
        device = (payload.get("deviceIntegrity") or {}).get("deviceRecognitionVerdict") or []
        if self.settings.integrity_require_device_integrity and "MEETS_DEVICE_INTEGRITY" not in device:
            return IntegrityVerdict(False, "device_integrity")
        return IntegrityVerdict(True)

    async def verify(self, token: str | None, expected_hash: str) -> IntegrityVerdict:
        if self.mode == "off":
            return IntegrityVerdict(True, "disabled")
        if not token:
            verdict = IntegrityVerdict(False, "missing_token")
        else:
            try:
                verdict = self.check_payload(await self.decode(token), expected_hash)
            except Exception as exc:  # noqa: BLE001 - network/auth problems must not crash requests
                log.warning("integrity decode failed: %s", exc)
                verdict = IntegrityVerdict(False, "decode_failed")
        if not verdict.ok and self.mode == "monitor":
            log.info("integrity check failed (monitor mode): %s", verdict.reason)
            return IntegrityVerdict(True, f"monitor:{verdict.reason}")
        return verdict
