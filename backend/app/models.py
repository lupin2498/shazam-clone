"""Database tables (design doc, section 8).

The backend stores track metadata and links only. User audio is never written
to disk or to the database.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

JSONType = JSON().with_variant(JSONB(), "postgresql")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Track(Base):
    """One row per recording."""

    __tablename__ = "track"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    isrc: Mapped[str | None] = mapped_column(String(16), unique=True, index=True)
    # Normalised "title|artist" used to de-duplicate tracks that have no ISRC.
    match_key: Mapped[str] = mapped_column(String(400), index=True)
    title: Mapped[str] = mapped_column(Text)
    artists: Mapped[list[str]] = mapped_column(JSONType, default=list)
    album: Mapped[str | None] = mapped_column(Text)
    duration_ms: Mapped[int | None] = mapped_column(Integer)
    artwork_url: Mapped[str | None] = mapped_column(Text)
    is_instrumental: Mapped[bool] = mapped_column(Boolean, default=False)
    # Composition title for classical music and covers.
    work_title: Mapped[str | None] = mapped_column(Text)
    genres: Mapped[list[str]] = mapped_column(JSONType, default=list)
    release_date: Mapped[str | None] = mapped_column(String(32))
    # Platform ids returned by the engines: spotify, youtube, deezer, apple_music_url, acrid...
    external_ids: Mapped[dict[str, str]] = mapped_column(JSONType, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class TrackLink(Base):
    __tablename__ = "track_link"
    __table_args__ = (
        UniqueConstraint("track_id", "country", "platform", "kind", "url", name="uq_track_link"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    track_id: Mapped[str] = mapped_column(ForeignKey("track.id", ondelete="CASCADE"), index=True)
    platform: Mapped[str] = mapped_column(String(32))
    url: Mapped[str] = mapped_column(Text)
    # listen | buy | free_download | offline_in_app
    kind: Mapped[str] = mapped_column(String(16))
    # exact | search
    match: Mapped[str] = mapped_column(String(8))
    license: Mapped[str | None] = mapped_column(String(128))
    country: Mapped[str] = mapped_column(String(2))
    score: Mapped[float] = mapped_column(Float, default=0.0)
    # Title and duration of the item found on the platform (shown in the result list).
    title: Mapped[str | None] = mapped_column(Text)
    duration_ms: Mapped[int | None] = mapped_column(Integer)
    hidden: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Recognition(Base):
    __tablename__ = "recognition"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64), index=True)  # anonymous id
    session_id: Mapped[str | None] = mapped_column(String(64))
    source: Mapped[str] = mapped_column(String(8))  # mic | file | hum | playback
    mode: Mapped[str] = mapped_column(String(8))  # auto | hum
    stage: Mapped[str] = mapped_column(String(8))  # early | full
    engine: Mapped[str | None] = mapped_column(String(32))
    status: Mapped[str] = mapped_column(String(16))  # matched | candidates | no_match
    top_track_id: Mapped[str | None] = mapped_column(ForeignKey("track.id", ondelete="SET NULL"))
    confidence: Mapped[float | None] = mapped_column(Float)
    latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class Candidate(Base):
    __tablename__ = "candidate"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    recognition_id: Mapped[str] = mapped_column(ForeignKey("recognition.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[str] = mapped_column(ForeignKey("track.id", ondelete="CASCADE"))
    confidence: Mapped[float] = mapped_column(Float)
    rank: Mapped[int] = mapped_column(Integer)
    flags: Mapped[list[str]] = mapped_column(JSONType, default=list)


class LinkReport(Base):
    __tablename__ = "link_report"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    link_id: Mapped[str] = mapped_column(ForeignKey("track_link.id", ondelete="CASCADE"), index=True)
    device_id: Mapped[str] = mapped_column(String(64))
    reason: Mapped[str] = mapped_column(String(32))
    note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # Moderation: reviewed within 48 h (section 7).
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolution: Mapped[str | None] = mapped_column(String(16))  # restored | removed


class RecognitionReport(Base):
    """"Báo sai" on the result screen: the user says the recognised song is wrong."""

    __tablename__ = "recognition_report"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    recognition_id: Mapped[str] = mapped_column(ForeignKey("recognition.id", ondelete="CASCADE"), index=True)
    device_id: Mapped[str] = mapped_column(String(64))
    reason: Mapped[str] = mapped_column(String(32))
    note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
