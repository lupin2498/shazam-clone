"""FastAPI application: the app talks only to this backend (section 4)."""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI

from . import __version__
from .cache import make_cache
from .config import Settings, get_settings
from .db import Database
from .errors import install_handlers
from .limits import FORM_OVERHEAD_BYTES, BodyLimitMiddleware, keep_uploads_in_memory
from .logsafe import configure_logging
from .routers import admin, config, links, recognitions, search, tracks
from .services.container import Services, build_services


def create_app(settings: Settings | None = None,
               customize: Callable[[Services], None] | None = None) -> FastAPI:
    """``customize`` lets tests swap engines or adapters after the services are built."""
    settings = settings or get_settings()
    configure_logging(settings.log_level)
    if settings.is_production and settings.demo_mode:
        raise RuntimeError("DEMO_MODE must not be enabled in production")

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        http = httpx.AsyncClient(
            timeout=httpx.Timeout(10.0, connect=5.0),
            headers={"User-Agent": f"TimNhac-Backend/{__version__}"},
            follow_redirects=True,
        )
        db = Database(settings.database_url)
        if settings.create_tables:
            await db.create_all()
        cache = make_cache(settings.redis_url)
        services = build_services(settings, http, db, cache)
        if customize:
            customize(services)
        app.state.services = services
        try:
            yield
        finally:
            await http.aclose()
            await cache.close()
            await db.dispose()

    app = FastAPI(title="Tìm Nhạc API", version=__version__, lifespan=lifespan)
    app.add_middleware(BodyLimitMiddleware, max_bytes=settings.max_upload_bytes + FORM_OVERHEAD_BYTES)
    keep_uploads_in_memory(settings.max_upload_bytes)
    install_handlers(app)
    for module in (recognitions, tracks, search, links, config, admin):
        app.include_router(module.router)

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
