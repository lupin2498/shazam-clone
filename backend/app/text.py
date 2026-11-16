"""Text normalisation, instrumental detection and match scoring (section 5 & 6, step 4)."""

from __future__ import annotations

import re
import unicodedata

from rapidfuzz import fuzz

# Words that mark a recording without vocals. Kept *in* normalised titles on purpose:
# "Song (Instrumental)" and "Song" are different recordings.
_STRONG_MARKERS = [
    r"instrumental", r"karaoke", r"khong loi", r"hoa tau", r"off ?vocal", r"minus ?one", r"backing track",
    r"piano (?:version|cover|ver\.?)", r"guitar (?:version|cover)", r"violin cover", r"nhac nen",
    r"music box (?:version|cover)", r"orchestral version", r"lofi version",
]
# Ambiguous words ("Beat It") only count inside a version tag: "(Beat)", "[MR]", "- Inst.", or at the very end.
_WEAK_MARKERS = [r"beat", r"inst\.?", r"bgm", r"mr"]
_STRONG_RE = re.compile(r"(?<![a-z0-9])(?:" + "|".join(_STRONG_MARKERS) + r")(?![a-z0-9])")
_WEAK_RE = re.compile(r"(?<![a-z0-9])(?:" + "|".join(_WEAK_MARKERS) + r")(?![a-z0-9])")
_WEAK_TAIL_RE = re.compile(r"(?<![a-z0-9])(?:" + "|".join(_WEAK_MARKERS) + r")\s*$")
_VERSION_TAGS = re.compile(r"[(\[【]([^)\]】]*)[)\]】]|\s[-–—|]\s(.*)$")
_INSTRUMENTAL_RE = re.compile(_STRONG_RE.pattern + "|" + _WEAK_RE.pattern)

_INSTRUMENTAL_GENRES = {
    "classical", "soundtrack", "score", "instrumental", "ambient", "new age", "lo-fi", "lofi",
    "piano", "orchestral", "film score", "chillhop", "meditation", "baroque", "opera instrumental",
}
_CLASSICAL_GENRES = {"classical", "baroque", "romantic", "opera", "chamber music", "orchestral"}
_CLASSICAL_RE = re.compile(
    r"(?<![a-z0-9])(?:op\.? ?\d+|bwv ?\d+|k\. ?\d+|kv ?\d+|hob\.|symphony no|concerto|sonata|"
    r"nocturne|etude|prelude|fugue|requiem|suite no|rv ?\d+)(?![a-z])"
)

# Decorations that platforms add to titles: "Official MV", "Lyrics", "[4K]", "(Audio)"...
_NOISE_IN_BRACKETS = re.compile(
    r"[(\[【]\s*(?:official|lyrics?|lyric video|video|audio|mv|m/v|music video|visuali[sz]er|hd|hq|4k|"
    r"explicit|clean|remaster(?:ed)?|live|vietsub|engsub|full)[^)\]】]*[)\]】]"
)
_NOISE_WORDS = re.compile(
    r"(?<![a-z0-9])(?:official (?:music )?(?:video|mv|audio|lyrics? video|visuali[sz]er)|lyrics? video|lyrics?|"
    r"m/?v|music video|hd|hq|4k|vietsub|engsub)(?![a-z0-9])"
)
# Other versions of a song: a result carrying one of these while the target does not is a different recording.
_VERSION_WORDS = re.compile(
    r"(?<![a-z0-9])(?:cover|remix|live|acoustic|sped up|slowed|nightcore|8d|reverb|mashup|"
    r"tiktok|remake|parody|reaction)(?![a-z0-9])"
)
_FEAT = re.compile(r"(?<![a-z0-9])(?:ft|feat|featuring)\.?\s.*$")
_TOPIC = re.compile(r"\s*-\s*topic$|vevo$")
_NON_WORD = re.compile(r"[^\w\s]", re.UNICODE)
_SPACES = re.compile(r"\s+")


def strip_diacritics(text: str) -> str:
    text = text.replace("đ", "d").replace("Đ", "D")
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def basic(text: str) -> str:
    return _SPACES.sub(" ", strip_diacritics(text or "").lower()).strip()


def normalize_title(title: str) -> str:
    t = basic(title)
    t = _NOISE_IN_BRACKETS.sub(" ", t)
    t = _FEAT.sub(" ", t)
    t = _NOISE_WORDS.sub(" ", t)
    t = _NON_WORD.sub(" ", t)
    return _SPACES.sub(" ", t).strip()


def normalize_artist(artist: str) -> str:
    a = _TOPIC.sub("", basic(artist))
    a = _NON_WORD.sub(" ", a)
    return _SPACES.sub(" ", a).strip()


def match_key(title: str, artists: list[str]) -> str:
    first = artists[0] if artists else ""
    return f"{normalize_title(title)}|{normalize_artist(first)}"[:400]


def has_instrumental_marker(text: str) -> bool:
    t = basic(text)
    if _STRONG_RE.search(t) or _WEAK_TAIL_RE.search(t):
        return True
    for m in _VERSION_TAGS.finditer(t):
        tag = m.group(1) or m.group(2) or ""
        if _WEAK_RE.search(tag):
            return True
    return False


def is_classical(title: str, genres: list[str]) -> bool:
    if any(basic(g) in _CLASSICAL_GENRES for g in genres):
        return True
    return bool(_CLASSICAL_RE.search(basic(title)))


def infer_instrumental(title: str, genres: list[str], album: str | None = None) -> bool:
    """``is_instrumental`` flag: engine metadata (genres) + keywords in the title (section 5)."""
    if has_instrumental_marker(title) or (album and has_instrumental_marker(album)):
        return True
    return any(basic(g) in _INSTRUMENTAL_GENRES for g in genres)


def is_instrumental_version(title: str) -> bool:
    """True for a no-vocals *version* of a song (beat, karaoke...), as opposed to music that is instrumental by nature."""
    return has_instrumental_marker(title)


def same_song(title_a: str, title_b: str, min_ratio: int = 85) -> bool:
    """Same composition once instrumental markers and decorations are ignored."""
    a = _SPACES.sub(" ", _INSTRUMENTAL_RE.sub(" ", normalize_title(title_a))).strip()
    b = _SPACES.sub(" ", _INSTRUMENTAL_RE.sub(" ", normalize_title(title_b))).strip()
    return bool(a and b) and fuzz.token_set_ratio(a, b) >= min_ratio


def score_match(
    *,
    title: str,
    artists: list[str],
    duration_ms: int | None,
    cand_title: str,
    cand_artist: str | None,
    cand_duration_ms: int | None,
    tolerance_s: float = 3.0,
    require_instrumental: bool = False,
) -> float:
    """Score a name-based search result against the recognised track, 0..1.

    Returns 0 when the result must be rejected: duration off by more than
    ``tolerance_s`` or a vocal version when an instrumental one is required.
    """
    if require_instrumental and not has_instrumental_marker(cand_title):
        return 0.0
    if duration_ms and cand_duration_ms and abs(duration_ms - cand_duration_ms) > tolerance_s * 1000:
        return 0.0

    t_target = normalize_title(title)
    t_cand = normalize_title(cand_title)
    if not t_target or not t_cand:
        return 0.0
    title_sim = fuzz.token_set_ratio(t_target, t_cand) / 100.0
    # Missing instrumental marker on one side only → different recording.
    if has_instrumental_marker(title) != has_instrumental_marker(cand_title):
        title_sim *= 0.3
    # "... (Cover)", "... Remix", "Live at ..." when the recognised track is not that version.
    target_versions = set(_VERSION_WORDS.findall(basic(title)))
    if set(_VERSION_WORDS.findall(basic(cand_title))) - target_versions:
        title_sim *= 0.3

    if artists:
        artist_sim = 0.0
        cand_a = normalize_artist(cand_artist or "")
        for a in artists:
            na = normalize_artist(a)
            if not na:
                continue
            by_field = fuzz.token_set_ratio(na, cand_a) / 100.0 if cand_a else 0.0
            # "Queen - Bohemian Rhapsody": artist named in the title (YouTube, web pages).
            in_title = 1.0 if re.search(rf"(?<![a-z0-9]){re.escape(na)}(?![a-z0-9])", t_cand) else 0.0
            artist_sim = max(artist_sim, by_field, in_title)
        if artist_sim < 0.6:
            artist_sim = 0.0
    else:
        artist_sim = 0.5

    if duration_ms and cand_duration_ms:
        dur = 1.0
    else:
        dur = 0.5
    return round(0.55 * title_sim + 0.30 * artist_sim + 0.15 * dur, 4)
