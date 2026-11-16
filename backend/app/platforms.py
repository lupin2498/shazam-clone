"""Registry of music platforms the resolver can link to.

``search_url`` templates take ``{q}`` (query-string encoded), ``{qp}`` (path encoded)
and ``{country}`` (lower-case ISO code). They can be overridden at runtime with
``SEARCH_URL_OVERRIDES`` and are published to the app through ``/v1/config``.
"""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import quote, quote_plus


@dataclass(frozen=True)
class Platform:
    id: str
    name: str
    color: str
    android_package: str | None = None
    search_url: str | None = None
    # The official app can download for offline listening (section 7, "Tải offline trong app chính chủ").
    offline_in_app: bool = False
    offline_note: str | None = None


PLATFORMS: dict[str, Platform] = {
    p.id: p
    for p in [
        Platform("youtube", "YouTube", "#FF0000", "com.google.android.youtube",
                 "https://www.youtube.com/results?search_query={q}"),
        Platform("youtube_music", "YouTube Music", "#FF0033", "com.google.android.apps.youtube.music",
                 "https://music.youtube.com/search?q={q}", True, "Cần YouTube Premium"),
        Platform("spotify", "Spotify", "#1DB954", "com.spotify.music",
                 "https://open.spotify.com/search/{qp}", True, "Cần Spotify Premium"),
        Platform("soundcloud", "SoundCloud", "#FF5500", "com.soundcloud.android",
                 "https://soundcloud.com/search/sounds?q={q}"),
        Platform("apple_music", "Apple Music", "#FA243C", "com.apple.android.music",
                 "https://music.apple.com/{country}/search?term={q}"),
        Platform("itunes", "iTunes Store", "#EA4CC0", None, None),
        Platform("deezer", "Deezer", "#A238FF", "deezer.android.app",
                 "https://www.deezer.com/search/{qp}"),
        Platform("zing_mp3", "Zing MP3", "#8D22C3", "com.zing.mp3",
                 "https://zingmp3.vn/tim-kiem/bai-hat?q={q}", True),
        Platform("nct", "NhacCuaTui", "#2DAAED", "ht.nct",
                 "https://www.nhaccuatui.com/tim-kiem/bai-hat?q={q}", True),
        Platform("tidal", "TIDAL", "#000000", "com.aspiro.tidal", "https://listen.tidal.com/search?q={q}"),
        Platform("amazon_music", "Amazon Music", "#25D1DA", "com.amazon.mp3",
                 "https://music.amazon.com/search/{qp}"),
        Platform("amazon_store", "Amazon", "#FF9900", None, None),
        Platform("bandcamp", "Bandcamp", "#1DA0C3", "com.bandcamp.android",
                 "https://bandcamp.com/search?q={q}&item_type=t"),
        Platform("pandora", "Pandora", "#3668FF", "com.pandora.android"),
        Platform("napster", "Napster", "#2259FF", "com.rhapsody"),
        Platform("audiomack", "Audiomack", "#FFA200", "com.audiomack"),
        Platform("anghami", "Anghami", "#9B2FAE", "com.anghami"),
        Platform("boomplay", "Boomplay", "#0A97D9", "com.afmobi.boomplayer"),
        Platform("yandex", "Yandex Music", "#FFCC00", "ru.yandex.music"),
        Platform("audius", "Audius", "#CC0FE0", "co.audius.app"),
        Platform("jamendo", "Jamendo", "#E8195B", None, "https://www.jamendo.com/search?q={q}"),
        Platform("internet_archive", "Internet Archive", "#666666", None,
                 "https://archive.org/search?query={q}&and%5B%5D=mediatype%3A%22audio%22"),
        Platform("free_music_archive", "Free Music Archive", "#D5354F", None,
                 "https://freemusicarchive.org/search?quicksearch={q}"),
        Platform("musopen", "Musopen", "#2B5C8A", None, "https://musopen.org/music/?search={q}"),
        Platform("web", "Web", "#607D8B"),
    ]
}


def search_url(platform_id: str, query: str, country: str = "VN", overrides: dict[str, str] | None = None) -> str | None:
    template = (overrides or {}).get(platform_id) or PLATFORMS[platform_id].search_url
    if not template:
        return None
    return template.format(q=quote_plus(query), qp=quote(query, safe=""), country=country.lower())
