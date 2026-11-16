"""requestHash shared with the app.

The same constants live in mobile/test/contract_test.dart, which checks the hash inside the
integrity token the app really sends. Changing the format on one side breaks a test there.
"""
from app.security.integrity import request_hash, sha256_hex

AUDIO = bytes([1, 2, 3])
AUDIO_SHA = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"


def test_audio_digest():
    assert sha256_hex(AUDIO) == AUDIO_SHA


def test_recognition_hash_with_and_without_session():
    # routers/recognitions.py: request_hash(device, session_id or "", stage, sha256_hex(data))
    assert request_hash("dev-123", "sess-1", "full", AUDIO_SHA) == (
        "e07a9bf6e96698cf41b03031452709106929df467e2b57d4f83645e364736f7a")
    assert request_hash("dev-123", "", "early", AUDIO_SHA) == (
        "4af569da140870f657caa47fdd30ccc8e215d1983d88cd4f02acb1f1798a9445")


def test_search_hash_uses_the_raw_utf8_query():
    # routers/search.py hashes q as received (before strip), UTF-8, no normalisation.
    assert request_hash("dev-123", "search", "Nơi này có anh") == (
        "b31fda262bb7fa913b2529db5a202a6b8cbcd9614d1eaf78dcffa99c2a8381ef")


def test_report_hash():
    # routers/links.py: request_hash(device, "report", link_id, body.reason)
    assert request_hash("dev-123", "report", "lnk_1", "violation") == (
        "21eabc87dadb5e8a5974d4c2d616cc514d9d4b871d7e29466923a6c41e69e2c1")
