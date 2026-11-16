"""Runtime configuration, read from environment variables (or a .env file).

Every API key lives here, on the backend only: the mobile app never ships a key
(design doc, section 9).
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    environment: str = "development"  # development | production
    database_url: str = "sqlite+aiosqlite:///./timnhac.db"
    # Empty → in-process memory cache (only for development and tests).
    redis_url: str = ""
    create_tables: bool = True
    log_level: str = "INFO"
    admin_token: str = ""

    # --- Recognition engines (section 5) -------------------------------------
    acrcloud_host: str = ""
    acrcloud_access_key: str = ""
    acrcloud_access_secret: str = ""
    # Separate ACRCloud project for "Cover Song (humming)". Empty → reuse the main project.
    acrcloud_hum_host: str = ""
    acrcloud_hum_access_key: str = ""
    acrcloud_hum_access_secret: str = ""
    audd_api_token: str = ""
    # Returns canned results without calling any engine. Never enable in production.
    demo_mode: bool = False
    engine_timeout_s: float = 10.0

    # ACRCloud fingerprint score is 0-100.
    acr_min_score: int = 70
    # "High score" required to stop listening after the first 6 s probe.
    acr_early_min_score: int = 85
    hum_min_confidence: float = 0.3
    # AudD does not return a score; a match is reported with this confidence.
    audd_confidence: float = 0.9
    max_candidates: int = 3
    artwork_lookup_timeout_s: float = 1.5

    # --- Uploaded samples -------------------------------------------------------
    max_sample_seconds: float = 15.5
    max_upload_bytes: int = 2_000_000

    # --- Abuse protection (sections 8, 10) -------------------------------------
    integrity_mode: str = "off"  # off | monitor | enforce
    play_package_name: str = "vn.timnhac.app"
    # Google Cloud project number the app passes to the Play Integrity API (not a secret).
    play_cloud_project_number: str = ""
    google_service_account_file: str = ""
    integrity_max_age_s: int = 600
    integrity_require_device_integrity: bool = True
    quota_per_device_per_day: int = 30
    search_per_device_per_day: int = 200
    quota_timezone_offset_hours: int = 7  # quota day resets at local midnight (Vietnam)
    min_app_version: str = "1.0.0"

    # --- Link resolver (sections 6, 7) ----------------------------------------
    adapter_timeout_s: float = 3.0
    match_score_threshold: float = 0.72
    duration_tolerance_s: float = 3.0
    link_cache_ttl_exact_s: int = 30 * 86400
    link_cache_ttl_empty_s: int = 86400
    link_cache_ttl_degraded_s: int = 300
    enabled_adapters: str = (
        "youtube,youtube_music,spotify,soundcloud,apple_music,deezer,zing_mp3,nct,"
        "odesli,bandcamp,jamendo,internet_archive,cc_search,web_search"
    )
    default_country: str = "VN"
    circuit_failure_threshold: int = 5
    circuit_reset_s: int = 60
    report_hide_threshold: int = 3

    youtube_api_key: str = ""
    youtube_search_daily_limit: int = 100
    spotify_client_id: str = ""
    spotify_client_secret: str = ""
    soundcloud_client_id: str = ""
    soundcloud_client_secret: str = ""
    jamendo_client_id: str = ""
    odesli_enabled: bool = True
    odesli_per_minute: int = 10
    # Whitelisted web search (F9). Provider: Brave Search API. Empty key → disabled.
    brave_search_api_key: str = ""
    web_search_whitelist: str = (
        "bandcamp.com,freemusicarchive.org,jamendo.com,archive.org,musopen.org,ccmixter.org"
    )
    # Deep search URL templates can be overridden without an app release, e.g.
    # SEARCH_URL_OVERRIDES='{"zing_mp3": "https://zingmp3.vn/tim-kiem/tat-ca?q={q}"}'
    search_url_overrides: dict[str, str] = {}

    @property
    def is_production(self) -> bool:
        return self.environment.lower() == "production"

    @property
    def enabled_adapter_ids(self) -> list[str]:
        return [a.strip() for a in self.enabled_adapters.split(",") if a.strip()]

    @property
    def web_whitelist(self) -> set[str]:
        return {d.strip().lower() for d in self.web_search_whitelist.split(",") if d.strip()}

    @property
    def acr_configured(self) -> bool:
        return bool(self.acrcloud_host and self.acrcloud_access_key and self.acrcloud_access_secret)

    @property
    def acr_hum_configured(self) -> bool:
        if self.acrcloud_hum_host:
            return bool(self.acrcloud_hum_access_key and self.acrcloud_hum_access_secret)
        return self.acr_configured


@lru_cache
def get_settings() -> Settings:
    return Settings()
