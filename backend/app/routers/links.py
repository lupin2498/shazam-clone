"""``POST /v1/links/{id}/report``: a link reported as a violation is hidden at once (section 7)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Header
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import device_id, get_services, get_session, require_integrity
from ..errors import ApiError
from ..models import LinkReport, TrackLink
from ..schemas import LinkReportIn, LinkReportOut
from ..security.integrity import request_hash
from ..services.container import Services

router = APIRouter(prefix="/v1", tags=["links"])


@router.post("/links/{link_id}/report", status_code=202, response_model=LinkReportOut)
async def report_link(
    link_id: str,
    body: LinkReportIn,
    device: str = Depends(device_id),
    x_integrity_token: str | None = Header(default=None),
    services: Services = Depends(get_services),
    session: AsyncSession = Depends(get_session),
) -> LinkReportOut:
    await require_integrity(services, x_integrity_token, request_hash(device, "report", link_id, body.reason))
    link = await session.get(TrackLink, link_id)
    if link is None:
        raise ApiError(404, "not_found", "Không tìm thấy link.")
    # One report per device and link.
    if not await services.cache.set_nx(f"report:{device}:{link_id}", "1", 30 * 86400):
        return LinkReportOut(hidden=link.hidden)
    session.add(LinkReport(link_id=link_id, device_id=device, reason=body.reason, note=body.note))
    await session.flush()
    if body.reason == "violation":
        link.hidden = True
    else:
        count = (await session.execute(
            select(func.count()).select_from(LinkReport).where(
                LinkReport.link_id == link_id, LinkReport.resolved_at.is_(None))
        )).scalar_one()
        if count >= services.settings.report_hide_threshold:
            link.hidden = True
    await session.commit()
    return LinkReportOut(hidden=link.hidden)
