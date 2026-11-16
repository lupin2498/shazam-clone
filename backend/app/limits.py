"""Bound what a client may upload, before any of it is parsed or stored.

FastAPI parses the whole multipart body before the endpoint (and its checks) run. Without
a limit anyone can send gigabytes; Starlette spools everything above 1 MiB to a temporary
file first. The limit here is the largest legitimate request (one sample plus the form
fields), and samples within it stay in memory, as the privacy notice promises.
"""

from __future__ import annotations

import json
from typing import Any

from starlette.formparsers import MultiPartParser
from starlette.types import ASGIApp, Message, Receive, Scope, Send

# Room for the multipart boundaries and the few short form fields next to the sample.
FORM_OVERHEAD_BYTES = 64 * 1024


class BodyLimitMiddleware:
    """Answers 413 as soon as a request body is known to exceed ``max_bytes``.

    A declared ``Content-Length`` is refused without reading anything; a chunked body is
    cut off at the limit.
    """

    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("method") not in ("POST", "PUT", "PATCH"):
            await self.app(scope, receive, send)
            return
        declared = dict(scope.get("headers") or []).get(b"content-length", b"")
        if declared.isdigit() and int(declared) > self.max_bytes:
            await self._refuse(send)
            return

        received = 0
        too_large = False
        started = False
        refused = False

        async def limited_receive() -> Message:
            nonlocal received, too_large
            if too_large:
                return {"type": "http.disconnect"}
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body") or b"")
                if received > self.max_bytes:
                    # Stop feeding the app: to it the client is gone. Whatever it answers to
                    # that (FastAPI turns a failed body read into a 400) is replaced below.
                    too_large = True
                    return {"type": "http.disconnect"}
            return message

        async def guarded_send(message: Message) -> None:
            nonlocal started, refused
            if too_large and not started:
                if not refused:
                    refused = True
                    await self._refuse(send)
                return
            started = started or message["type"] == "http.response.start"
            await send(message)

        try:
            await self.app(scope, limited_receive, guarded_send)
        except Exception:
            if not too_large:
                raise
        if too_large and not started and not refused:
            await self._refuse(send)

    @staticmethod
    async def _refuse(send: Send) -> None:
        body: dict[str, Any] = {"error": "payload_too_large", "message": "Mẫu âm thanh quá lớn."}
        payload = json.dumps(body, ensure_ascii=False).encode()
        await send({"type": "http.response.start", "status": 413, "headers": [
            (b"content-type", b"application/json; charset=utf-8"),
            (b"content-length", str(len(payload)).encode()),
            (b"connection", b"close"),
        ]})
        await send({"type": "http.response.body", "body": payload})


def keep_uploads_in_memory(max_upload_bytes: int) -> None:
    """Samples are never written to disk (design doc sections 8 and 10): raise the size from
    which Starlette moves an uploaded part to a temporary file above the largest sample."""
    MultiPartParser.spool_max_size = max(MultiPartParser.spool_max_size, max_upload_bytes + 1)
