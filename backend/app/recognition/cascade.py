"""Engine cascade (design doc, section 5 "Thứ tự xếp tầng").

1. ``stage=early`` (6 s probe): ACRCloud; accept only a high score so the app can stop listening.
2. ``stage=full`` (12 s): ACRCloud again.
3. Still nothing: same sample to AudD.
4. Still nothing: ACRCloud Cover Song (humming); up to 3 candidates with confidence.
5. Nothing: ``no_match``.

``mode=hum`` (user hums/whistles) jumps straight to step 4.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Protocol

from ..config import Settings
from ..text import is_instrumental_version, normalize_artist, normalize_title, same_song
from .base import EngineError, EngineMatch
from .demo import demo_matches

log = logging.getLogger(__name__)


class FingerprintEngine(Protocol):
    name: str

    async def fingerprint(self, audio: bytes, filename: str) -> list[EngineMatch]: ...
    async def cover(self, audio: bytes, filename: str) -> list[EngineMatch]: ...


class SimpleEngine(Protocol):
    name: str

    async def identify(self, audio: bytes, filename: str) -> list[EngineMatch]: ...


class EnginesUnavailable(Exception):
    """Every engine that should have been called failed."""


@dataclass
class CascadeOutcome:
    status: str  # matched | candidates | no_match
    engine: str | None = None
    matches: list[EngineMatch] = field(default_factory=list)
    # For an early probe without a match the app keeps listening (final=False).
    final: bool = True
    # Other recordings the engine returned for the same audio (used for the "maybe beat" hint).
    alternates: list[EngineMatch] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def _dedupe(matches: list[EngineMatch]) -> list[EngineMatch]:
    seen: set[str] = set()
    out = []
    for m in matches:
        key = m.track.isrc or f"{normalize_title(m.track.title)}|{normalize_artist((m.track.artists or [''])[0])}"
        if key in seen:
            continue
        seen.add(key)
        out.append(m)
    return out


class RecognitionCascade:
    def __init__(self, settings: Settings, acr: FingerprintEngine | None, audd: SimpleEngine | None):
        self.settings = settings
        self.acr = acr
        self.audd = audd

    @property
    def available(self) -> bool:
        return self.settings.demo_mode or self.acr is not None or self.audd is not None

    @property
    def engine_names(self) -> list[str]:
        names = []
        if self.acr:
            names.append("ACRCloud")
        if self.audd:
            names.append("AudD")
        return names

    async def run(self, audio: bytes, filename: str, *, mode: str, stage: str) -> CascadeOutcome:
        if self.settings.demo_mode:
            status, matches = demo_matches(audio, mode)
            return CascadeOutcome(status=status, engine="demo", matches=matches)
        if mode == "hum":
            return await self._cover_step(audio, filename, errors=[], attempted=0)
        if stage == "early":
            return await self._early(audio, filename)
        return await self._full(audio, filename)

    async def _early(self, audio: bytes, filename: str) -> CascadeOutcome:
        if not self.acr:
            return CascadeOutcome(status="no_match", final=False)
        try:
            matches = _dedupe(await self.acr.fingerprint(audio, filename))
        except EngineError as exc:
            log.warning("early probe failed: %s", exc)
            return CascadeOutcome(status="no_match", engine="acrcloud", final=False, errors=[str(exc)])
        threshold = self.settings.acr_early_min_score / 100.0
        if matches and matches[0].confidence >= threshold:
            return CascadeOutcome(status="matched", engine="acrcloud", matches=matches[:1], alternates=matches[1:])
        return CascadeOutcome(status="no_match", engine="acrcloud", final=False)

    async def _full(self, audio: bytes, filename: str) -> CascadeOutcome:
        errors: list[str] = []
        attempted = 0
        if self.acr:
            attempted += 1
            try:
                matches = _dedupe(await self.acr.fingerprint(audio, filename))
                good = [m for m in matches if m.confidence >= self.settings.acr_min_score / 100.0]
                if good:
                    return CascadeOutcome(status="matched", engine="acrcloud", matches=good[:1],
                                          alternates=matches[1:], errors=errors)
            except EngineError as exc:
                log.warning("acrcloud failed: %s", exc)
                errors.append(str(exc))
        if self.audd:
            attempted += 1
            try:
                matches = await self.audd.identify(audio, filename)
                if matches:
                    return CascadeOutcome(status="matched", engine="audd", matches=matches[:1], errors=errors)
            except EngineError as exc:
                log.warning("audd failed: %s", exc)
                errors.append(str(exc))
        return await self._cover_step(audio, filename, errors=errors, attempted=attempted)

    async def _cover_step(self, audio: bytes, filename: str, *, errors: list[str], attempted: int) -> CascadeOutcome:
        if self.acr and self.settings.acr_hum_configured:
            attempted += 1
            try:
                matches = _dedupe(await self.acr.cover(audio, filename))
                good = [m for m in matches if m.confidence >= self.settings.hum_min_confidence]
                if good:
                    return CascadeOutcome(status="candidates", engine="acrcloud_cover",
                                          matches=good[: self.settings.max_candidates], errors=errors)
            except EngineError as exc:
                log.warning("acrcloud cover failed: %s", exc)
                errors.append(str(exc))
        if attempted and len(errors) == attempted:
            raise EnginesUnavailable("; ".join(errors))
        if not attempted:
            raise EnginesUnavailable("no recognition engine configured")
        return CascadeOutcome(status="no_match", errors=errors)


def candidate_flags(outcome: CascadeOutcome, *, mode: str, filename_hint: str | None) -> list[list[str]]:
    """Per-candidate hints for the result screen (section 5, "Nhạc không lời")."""
    flags: list[list[str]] = []
    hint_beat = bool(filename_hint and is_instrumental_version(filename_hint))
    for i, m in enumerate(outcome.matches):
        f: list[str] = []
        if mode == "hum":
            f.append("melody")
        elif m.via == "cover":
            # Matched only through melody: the sample is probably a cover/re-arrangement.
            f.append("cover")
        if i == 0 and outcome.status == "matched" and not is_instrumental_version(m.track.title):
            # The engine also returned an instrumental release of the same song, or the
            # shared file is named "... beat/karaoke": the sample may be the beat.
            beat_alternate = any(
                is_instrumental_version(a.track.title) and same_song(a.track.title, m.track.title)
                for a in outcome.alternates
            )
            if hint_beat or beat_alternate:
                f.append("maybe_beat")
        flags.append(f)
    return flags
