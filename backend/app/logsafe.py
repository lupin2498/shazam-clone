"""Keep API keys out of the logs.

Some platforms take their key in the query string (YouTube ``key=``, Jamendo
``client_id=``). httpx writes the full URL both in its INFO request log and in the
text of ``HTTPStatusError``, so without care every search would print the key.
"""

from __future__ import annotations

import logging
import re

_SECRET_PARAMS = (
    "key|api_key|apikey|api_token|token|access_token|access_key|access_secret|client_id|client_secret|"
    "signature|password|secret"
)
_PATTERN = re.compile(rf"(?i)(^|[?&;\s'\"(])({_SECRET_PARAMS})=([^&\s'\"#)]+)")


def redact(text: object) -> str:
    """Mask the value of secret-looking query parameters: ``...&key=AIza...`` → ``...&key=***``."""
    return _PATTERN.sub(r"\1\2=***", str(text))


class RedactSecretsFilter(logging.Filter):
    """Last line of defence on the log handlers: masks secrets in any formatted message."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - never break logging
            return True
        clean = redact(message)
        if clean != message:
            record.msg, record.args = clean, None
        return True


def configure_logging(level: str) -> None:
    logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # httpx logs "HTTP Request: GET <full url>" at INFO for every call; those URLs carry keys.
    for name in ("httpx", "httpcore"):
        logger = logging.getLogger(name)
        logger.setLevel(max(logging.WARNING, logger.level))
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, RedactSecretsFilter) for f in handler.filters):
            handler.addFilter(RedactSecretsFilter())
