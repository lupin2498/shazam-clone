"""Moderation of reported links (reviewed within 48 h, section 7). Requires ``ADMIN_TOKEN``."""

from __future__ import annotations

import hmac
from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import get_services, get_session
from ..errors import ApiError
from ..models import LinkReport, TrackLink
from ..services.container import Services

router = APIRouter(prefix="/admin", tags=["admin"], include_in_schema=False)


def require_admin(x_admin_token: str | None = Header(default=None), services: Services = Depends(get_services)) -> None:
    expected = services.settings.admin_token
    if not expected or not x_admin_token or not hmac.compare_digest(expected, x_admin_token):
        raise ApiError(401, "unauthorized", "Unauthorized")


class ResolveIn(BaseModel):
    action: Literal["restore", "remove"]


@router.get("/reports", dependencies=[Depends(require_admin)])
async def list_reports(session: AsyncSession = Depends(get_session)) -> list[dict[str, Any]]:
    rows = await session.execute(
        select(LinkReport, TrackLink).join(TrackLink, TrackLink.id == LinkReport.link_id)
        .where(LinkReport.resolved_at.is_(None)).order_by(LinkReport.created_at).limit(200)
    )
    return [
        {"report_id": r.id, "reason": r.reason, "note": r.note, "created_at": r.created_at.isoformat(),
         "link": {"id": l.id, "platform": l.platform, "url": l.url, "kind": l.kind, "hidden": l.hidden,
                  "track_id": l.track_id}}
        for r, l in rows
    ]


@router.post("/links/{link_id}/resolve", dependencies=[Depends(require_admin)])
async def resolve_link(link_id: str, body: ResolveIn, session: AsyncSession = Depends(get_session)) -> dict[str, Any]:
    link = await session.get(TrackLink, link_id)
    if link is None:
        raise ApiError(404, "not_found", "Link not found")
    link.hidden = body.action == "remove"
    now = datetime.now(timezone.utc)
    reports = await session.execute(select(LinkReport).where(LinkReport.link_id == link_id,
                                                             LinkReport.resolved_at.is_(None)))
    for (report,) in reports:
        report.resolved_at, report.resolution = now, ("removed" if link.hidden else "restored")
    await session.commit()
    return {"id": link.id, "hidden": link.hidden}
