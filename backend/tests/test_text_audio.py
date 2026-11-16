import pytest

from app.audio import InvalidSample, adts_duration, inspect_sample
from app.links.licenses import license_from_url, soundcloud_license
from app.text import (
    infer_instrumental,
    is_classical,
    match_key,
    normalize_artist,
    normalize_title,
    same_song,
    score_match,
)
from tests.conftest import adts_stream, wav_bytes


def test_normalize_title_strips_decorations_and_diacritics():
    assert normalize_title("Sơn Tùng M-TP - Chúng Ta Của Hiện Tại (Official MV) [4K]") == \
        "son tung m tp chung ta cua hien tai"
    assert normalize_title("Bohemian Rhapsody (Remastered 2011)") == "bohemian rhapsody"
    assert normalize_title("Lạc Trôi | Lyrics Video") == "lac troi"
    assert normalize_title("Despacito ft. Daddy Yankee") == "despacito"
    # Instrumental markers are part of the identity of a recording.
    assert normalize_title("Shape of You (Instrumental)") == "shape of you instrumental"


def test_normalize_artist_handles_youtube_channels():
    assert normalize_artist("Queen - Topic") == "queen"
    assert normalize_artist("Đen Vâu") == "den vau"


def test_match_key_is_stable():
    assert match_key("Nơi Này Có Anh", ["Sơn Tùng M-TP"]) == match_key("noi nay co anh", ["son tung m-tp"])


def test_score_match_accepts_decorated_titles():
    score = score_match(title="Bohemian Rhapsody", artists=["Queen"], duration_ms=354000,
                        cand_title="Queen – Bohemian Rhapsody (Official Video Remastered)",
                        cand_artist="Queen Official", cand_duration_ms=355000)
    assert score > 0.9


def test_score_match_rejects_duration_off_by_more_than_tolerance():
    assert score_match(title="Bohemian Rhapsody", artists=["Queen"], duration_ms=354000,
                       cand_title="Bohemian Rhapsody", cand_artist="Queen", cand_duration_ms=360000) == 0.0


def test_score_match_rejects_vocal_version_when_instrumental_required():
    assert score_match(title="Shape of You (Instrumental)", artists=["Ed Sheeran"], duration_ms=None,
                       cand_title="Shape of You", cand_artist="Ed Sheeran", cand_duration_ms=None,
                       require_instrumental=True) == 0.0
    assert score_match(title="Shape of You (Instrumental)", artists=["Ed Sheeran"], duration_ms=None,
                       cand_title="Shape of You - Instrumental", cand_artist="Ed Sheeran", cand_duration_ms=None,
                       require_instrumental=True) > 0.8


def test_score_match_penalises_wrong_artist():
    assert score_match(title="Hello", artists=["Adele"], duration_ms=None, cand_title="Hello",
                       cand_artist="Lionel Richie", cand_duration_ms=None) < 0.72


def test_instrumental_and_classical_detection():
    assert infer_instrumental("Nơi Này Có Anh (Beat)", [])
    assert infer_instrumental("Hoa Nở Không Màu - Karaoke", [])
    assert infer_instrumental("Song", ["Classical"])
    assert not infer_instrumental("Beautiful", ["Pop"])
    assert not infer_instrumental("Beat It", [])  # "Beat" inside a title word sequence is not a marker...
    assert is_classical("Piano Sonata No. 14, Op. 27 No. 2", [])
    assert is_classical("Clair de Lune", ["Classical"])
    assert same_song("Shape of You (Instrumental)", "Shape of You")
    assert not same_song("Shape of You (Instrumental)", "Perfect")


def test_licenses():
    assert license_from_url("http://creativecommons.org/licenses/by-nc-sa/3.0/") == "CC BY-NC-SA 3.0"
    assert license_from_url("https://creativecommons.org/publicdomain/zero/1.0/") == "CC0"
    assert license_from_url("https://example.com") is None
    assert soundcloud_license("cc-by") == "CC BY"
    assert soundcloud_license("all-rights-reserved") is None


def test_adts_duration():
    assert adts_duration(adts_stream(12.0)) == pytest.approx(12.0, abs=0.05)


def test_inspect_sample_accepts_aac_and_wav():
    assert inspect_sample(adts_stream(12.0), max_bytes=2_000_000, max_seconds=15.5).format == "aac"
    info = inspect_sample(wav_bytes(2.0), max_bytes=2_000_000, max_seconds=15.5)
    assert info.format == "wav" and info.duration_s == pytest.approx(2.0)


def test_inspect_sample_rejects_long_or_unknown_audio():
    with pytest.raises(InvalidSample):
        inspect_sample(adts_stream(20.0), max_bytes=2_000_000, max_seconds=15.5)
    with pytest.raises(InvalidSample):
        inspect_sample(b"not audio at all, sorry", max_bytes=2_000_000, max_seconds=15.5)
    with pytest.raises(InvalidSample):
        inspect_sample(wav_bytes(2.0), max_bytes=1000, max_seconds=15.5)


def test_score_match_rejects_other_versions():
    base = dict(title="Nơi Này Có Anh", artists=["Sơn Tùng M-TP"], duration_ms=260000, cand_duration_ms=260000)
    assert score_match(cand_title="Nơi Này Có Anh", cand_artist="Sơn Tùng M-TP", **base) > 0.9
    assert score_match(cand_title="Nơi Này Có Anh (Remix)", cand_artist="Sơn Tùng M-TP", **base) < 0.72
    assert score_match(cand_title="Nơi Này Có Anh - Acoustic Cover", cand_artist="Sơn Tùng M-TP", **base) < 0.72
    live = dict(base, title="Hotel California (Live)")
    assert score_match(cand_title="Hotel California - Live", cand_artist="Sơn Tùng M-TP", **live) > 0.72
