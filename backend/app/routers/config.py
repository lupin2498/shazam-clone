"""``GET /v1/config``: enabled platforms, thresholds, sample lengths and minimum app version.

Lets operators switch a source off or tune thresholds without an app release (section 10).
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends

from ..deps import get_services
from ..platforms import PLATFORMS
from ..services.container import Services

router = APIRouter(prefix="/v1", tags=["config"])

REPORT_REASONS = [
    {"id": "wrong_song", "label": "Sai bài"},
    {"id": "broken", "label": "Link hỏng"},
    {"id": "violation", "label": "Vi phạm bản quyền"},
    {"id": "other", "label": "Lý do khác"},
]


@router.get("/config")
async def get_config(services: Services = Depends(get_services)) -> dict[str, Any]:
    s = services.settings
    enabled = {a.name for a in services.resolver.adapters}
    reachable = {p for a in services.resolver.adapters for p in a.platforms}
    platforms = []
    for p in PLATFORMS.values():
        template = s.search_url_overrides.get(p.id) or p.search_url
        platforms.append({
            "id": p.id, "name": p.name, "color": p.color, "android_package": p.android_package,
            "offline_in_app": p.offline_in_app, "offline_note": p.offline_note,
            "search_url_template": template, "enabled": p.id in reachable,
        })
    return {
        "min_app_version": s.min_app_version,
        "quota_per_day": s.quota_per_device_per_day,
        "score_threshold": s.match_score_threshold,
        "sample": {
            "early_probe_s": 6, "full_s": 12, "hum_s": 15, "max_s": 15,
            "file_default_s": 12, "file_min_s": 10, "file_max_s": 15, "file_default_position": 0.3,
            "scan_step_s": 30, "silence_rms": 0.004,
        },
        "adapters": sorted(enabled),
        "platforms": platforms,
        "engines": services.cascade.engine_names,
        "report_reasons": REPORT_REASONS,
        "integrity": {"mode": s.integrity_mode, "cloud_project_number": s.play_cloud_project_number or None},
        "demo_mode": s.demo_mode,
    }
