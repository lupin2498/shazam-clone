from __future__ import annotations

from ...config import Settings
from ..base import Adapter
from .apple import AppleMusicAdapter
from .deezer import DeezerAdapter
from .odesli import OdesliAdapter
from .open_sources import BandcampAdapter, CreativeCommonsSearchAdapter, InternetArchiveAdapter, JamendoAdapter
from .soundcloud import SoundCloudAdapter
from .spotify import SpotifyAdapter
from .vn import NctAdapter, ZingMp3Adapter
from .web_search import WebSearchAdapter
from .youtube import YouTubeAdapter, YouTubeMusicAdapter

ALL_ADAPTERS: dict[str, type[Adapter]] = {
    cls.name: cls
    for cls in [
        YouTubeAdapter, YouTubeMusicAdapter, SpotifyAdapter, SoundCloudAdapter, AppleMusicAdapter,
        DeezerAdapter, ZingMp3Adapter, NctAdapter, OdesliAdapter, BandcampAdapter, JamendoAdapter,
        InternetArchiveAdapter, CreativeCommonsSearchAdapter, WebSearchAdapter,
    ]
}


def build_adapters(settings: Settings) -> list[Adapter]:
    adapters = []
    for name in settings.enabled_adapter_ids:
        cls = ALL_ADAPTERS.get(name)
        if cls is None:
            continue
        adapter = cls()
        if adapter.enabled(settings):
            adapters.append(adapter)
    return adapters
