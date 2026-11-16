from __future__ import annotations

import re

_CC_URL = re.compile(r"creativecommons\.org/(licenses|publicdomain)/([a-z\-]+)/?([\d.]+)?", re.I)

_SOUNDCLOUD = {
    "cc-by": "CC BY",
    "cc-by-sa": "CC BY-SA",
    "cc-by-nd": "CC BY-ND",
    "cc-by-nc": "CC BY-NC",
    "cc-by-nc-sa": "CC BY-NC-SA",
    "cc-by-nc-nd": "CC BY-NC-ND",
    "no-rights-reserved": "CC0",
}


def license_from_url(url: str | None) -> str | None:
    """``http://creativecommons.org/licenses/by-nc-sa/3.0/`` → ``CC BY-NC-SA 3.0``."""
    if not url:
        return None
    m = _CC_URL.search(url)
    if not m:
        return "Public Domain" if "publicdomain" in url.lower() else None
    kind, code, version = m.group(1).lower(), m.group(2).lower(), m.group(3)
    if kind == "publicdomain":
        return "CC0" if code == "zero" else "Public Domain"
    label = "CC " + code.upper()
    return f"{label} {version}" if version else label


def soundcloud_license(code: str | None) -> str | None:
    return _SOUNDCLOUD.get((code or "").lower())


def is_open_license(label: str | None) -> bool:
    return bool(label) and (label.startswith("CC") or label == "Public Domain")
