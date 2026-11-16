"""Long-lived service objects shared by the request handlers."""

from __future__ import annotations

from dataclasses import dataclass

import httpx

from ..cache import Cache
from ..config import Settings
from ..db import Database
from ..links.circuit import BreakerRegistry
from ..links.resolver import LinkResolver
from ..recognition.acrcloud import ACRCloudClient, ACRCloudEngine
from ..recognition.audd import AudDEngine
from ..recognition.cascade import RecognitionCascade
from ..security.integrity import IntegrityVerifier
from .catalog import Catalog


@dataclass
class Services:
    settings: Settings
    http: httpx.AsyncClient
    db: Database
    cache: Cache
    cascade: RecognitionCascade
    resolver: LinkResolver
    integrity: IntegrityVerifier
    catalog: Catalog


def build_cascade(settings: Settings, http: httpx.AsyncClient) -> RecognitionCascade:
    acr = None
    if settings.acr_configured:
        main = ACRCloudClient(http, settings.acrcloud_host, settings.acrcloud_access_key,
                              settings.acrcloud_access_secret, settings.engine_timeout_s)
        cover = main
        if settings.acrcloud_hum_host:
            cover = ACRCloudClient(http, settings.acrcloud_hum_host, settings.acrcloud_hum_access_key,
                                   settings.acrcloud_hum_access_secret, settings.engine_timeout_s)
        acr = ACRCloudEngine(main, cover if settings.acr_hum_configured else None)
    audd = AudDEngine(http, settings.audd_api_token, settings.audd_confidence) if settings.audd_api_token else None
    return RecognitionCascade(settings, acr, audd)


def build_services(settings: Settings, http: httpx.AsyncClient, db: Database, cache: Cache) -> Services:
    breakers = BreakerRegistry(settings.circuit_failure_threshold, settings.circuit_reset_s)
    return Services(
        settings=settings,
        http=http,
        db=db,
        cache=cache,
        cascade=build_cascade(settings, http),
        resolver=LinkResolver(settings, http, cache, db.sessionmaker, breakers),
        integrity=IntegrityVerifier(settings, http),
        catalog=Catalog(http, cache),
    )
