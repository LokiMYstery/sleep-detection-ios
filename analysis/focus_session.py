#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from analysis.analyze_session import (
    ROUTES,
    EpisodeSummary,
    first_event,
    first_rejection_after,
    infer_episodes,
    parse_datetime,
    payload_time,
    route_events,
)


@dataclass
class RouteFocus:
    route_id: str
    method: str | None
    candidate_onset: datetime | None
    confirmed_onset: datetime | None
    confirmed_at: datetime | None
    rejected_at: datetime | None
    onset_error_min: float | None
    confirm_delay_min: float | None
    confirm_gap_min: float | None
    episode_count: int
    reonset_count: int
    stale_anchor_reuse_count: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render focused markdown metrics for a SleepPOC session.")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--tz", default="Asia/Shanghai")
    parser.add_argument("--output-md", type=Path)
    return parser.parse_args()


def fmt_dt(dt: datetime | None, tz: ZoneInfo) -> str:
    if dt is None:
        return "n/a"
    return dt.astimezone(tz).strftime("%Y-%m-%d %H:%M:%S")


def fmt_short(dt: datetime | None, tz: ZoneInfo) -> str:
    if dt is None:
        return "n/a"
    return dt.astimezone(tz).strftime("%H:%M:%S")


def fmt_min(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:+.2f}"


def overlap(start_a: datetime, end_a: datetime, start_b: datetime, end_b: datetime) -> bool:
    return end_a >= start_b and start_a <= end_b


def load_data(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def truth_time(data: dict[str, Any]) -> datetime | None:
    return parse_datetime((data.get("truth") or {}).get("healthKitSleepOnset"))


def build_route_focus(data: dict[str, Any], truth: datetime | None) -> list[RouteFocus]:
    rows: list[RouteFocus] = []
    for route_id in ROUTES:
        events = route_events(data, route_id)
        episodes = infer_episodes(route_id, events)
        _, candidate_onset, _ = first_event(events, "candidateWindowEntered")
        confirmed_at, confirmed_onset, confirmed_payload = first_event(events, "confirmedSleep")
        rejected_at, _ = first_rejection_after(events, confirmed_at)

        onset_error_min = None
        confirm_delay_min = None
        confirm_gap_min = None
        if truth and confirmed_onset:
            onset_error_min = (confirmed_onset - truth).total_seconds() / 60.0
        if truth and confirmed_at:
            confirm_delay_min = (confirmed_at - truth).total_seconds() / 60.0
        if confirmed_at and confirmed_onset:
            confirm_gap_min = (confirmed_at - confirmed_onset).total_seconds() / 60.0

        stale_anchor_reuse_count = sum(
            1 for ep in episodes for note in ep.notes if "stale anchor reuse" in note or "reset artifact" in note
        )
        rows.append(
            RouteFocus(
                route_id=route_id,
                method=confirmed_payload.get("method"),
                candidate_onset=candidate_onset,
                confirmed_onset=confirmed_onset,
                confirmed_at=confirmed_at,
                rejected_at=rejected_at,
                onset_error_min=onset_error_min,
                confirm_delay_min=confirm_delay_min,
                confirm_gap_min=confirm_gap_min,
                episode_count=len(episodes),
                reonset_count=max(0, len(episodes) - 1),
                stale_anchor_reuse_count=stale_anchor_reuse_count,
            )
        )
    return rows


ROUTE_D_PARAMS = {
    "audioQuietThreshold": 0.02,
    "audioVarianceThreshold": 0.0003,
    "frictionEventThreshold": 1,
    "breathingMinPeriodicityScore": 0.43,
    "playbackLeakageRejectThreshold": 0.68,
    "disturbanceRejectThreshold": 0.62,
}


def quiet_audio(audio: dict[str, Any]) -> bool:
    return bool(audio.get("isSilent")) or (
        float(audio.get("envNoiseLevel", 0.0)) <= ROUTE_D_PARAMS["audioQuietThreshold"]
        and float(audio.get("envNoiseVariance", 0.0)) <= ROUTE_D_PARAMS["audioVarianceThreshold"]
        and int(audio.get("frictionEventCount", 0)) <= ROUTE_D_PARAMS["frictionEventThreshold"]
        and float(audio.get("disturbanceScore", 0.0)) < ROUTE_D_PARAMS["disturbanceRejectThreshold"] * 0.85
    )


def playback_polluted(audio: dict[str, Any]) -> bool:
    return float(audio.get("playbackLeakageScore", 0.0)) >= ROUTE_D_PARAMS["playbackLeakageRejectThreshold"]


def breathing_support_approx(audio: dict[str, Any]) -> bool:
    return (
        bool(audio.get("breathingPresent"))
        and float(audio.get("breathingPeriodicityScore", 0.0)) >= ROUTE_D_PARAMS["breathingMinPeriodicityScore"]
        and float(audio.get("breathingConfidence", 0.0)) >= 0.5
        and not playback_polluted(audio)
    )


def audio_disturbance(audio: dict[str, Any]) -> bool:
    return (
        float(audio.get("disturbanceScore", 0.0)) >= ROUTE_D_PARAMS["disturbanceRejectThreshold"]
        or playback_polluted(audio)
        or int(audio.get("frictionEventCount", 0)) > max(ROUTE_D_PARAMS["frictionEventThreshold"] * 2, 2)
    )


def summarize_iphone_windows(windows: list[dict[str, Any]]) -> dict[str, Any]:
    with_audio = [w for w in windows if w.get("audio")]
    if not with_audio:
        return {
            "count": len(windows),
            "audio_windows": 0,
            "quiet_count": 0,
            "silent_count": 0,
            "polluted_count": 0,
            "breathing_present_count": 0,
            "breathing_support_count": 0,
            "disturbance_count": 0,
            "max_playback_leakage": None,
            "max_disturbance": None,
        }

    return {
        "count": len(windows),
        "audio_windows": len(with_audio),
        "quiet_count": sum(1 for w in with_audio if quiet_audio(w["audio"])),
        "silent_count": sum(1 for w in with_audio if w["audio"].get("isSilent")),
        "polluted_count": sum(1 for w in with_audio if playback_polluted(w["audio"])),
        "breathing_present_count": sum(1 for w in with_audio if w["audio"].get("breathingPresent")),
        "breathing_support_count": sum(1 for w in with_audio if breathing_support_approx(w["audio"])),
        "disturbance_count": sum(1 for w in with_audio if audio_disturbance(w["audio"])),
        "max_playback_leakage": max(float(w["audio"].get("playbackLeakageScore", 0.0)) for w in with_audio),
        "max_disturbance": max(float(w["audio"].get("disturbanceScore", 0.0)) for w in with_audio),
    }


def toggles_for_d(data: dict[str, Any]) -> list[tuple[datetime, bool, dict[str, Any]]]:
    items = []
    for event in data.get("events", []):
        if event.get("routeId") == "D" and event.get("eventType") == "custom.audioBundledPlaybackToggled":
            payload = event.get("payload", {})
            items.append((parse_datetime(event.get("timestamp")), payload.get("enabled") == "true", payload))
    return [item for item in items if item[0] is not None]


def playback_intervals(data: dict[str, Any]) -> list[tuple[datetime, datetime | None, dict[str, Any]]]:
    intervals: list[tuple[datetime, datetime | None, dict[str, Any]]] = []
    current_start: datetime | None = None
    current_payload: dict[str, Any] | None = None
    for ts, enabled, payload in toggles_for_d(data):
        if enabled:
            current_start = ts
            current_payload = payload
        elif current_start is not None:
            intervals.append((current_start, ts, current_payload or {}))
            current_start = None
            current_payload = None
    if current_start is not None:
        intervals.append((current_start, None, current_payload or {}))
    return intervals


def route_d_event_lines(data: dict[str, Any], start: datetime, end: datetime | None, tz: ZoneInfo) -> list[str]:
    lines: list[str] = []
    effective_end = end or max(parse_datetime(e.get("timestamp")) for e in data.get("events", []) if parse_datetime(e.get("timestamp")) is not None)
    for event in data.get("events", []):
        if event.get("routeId") != "D":
            continue
        if event.get("eventType") not in {"candidateWindowEntered", "suspectedSleep", "confirmedSleep", "sleepRejected", "custom.audioBundledPlaybackToggled"}:
            continue
        ts = parse_datetime(event.get("timestamp"))
        if ts is None or not overlap(ts, ts, start, effective_end):
            continue
        lines.append(
            f"- {fmt_short(ts, tz)} `{event['eventType']}` {json.dumps(event.get('payload', {}), ensure_ascii=False, sort_keys=True)}"
        )
    return lines


def playback_section(data: dict[str, Any], tz: ZoneInfo) -> list[str]:
    lines = ["## Route D Playback / Microphone Focus"]
    intervals = playback_intervals(data)
    iphone = [w for w in data.get("windows", []) if w.get("source") == "iphone"]
    if not intervals:
        lines.append("- No `custom.audioBundledPlaybackToggled` intervals were found for Route D.")
        lines.append("")
        return lines

    for idx, (start, end, payload) in enumerate(intervals, start=1):
        effective_end = end or max(parse_datetime(w["endTime"]) for w in iphone if parse_datetime(w.get("endTime")) is not None)
        during = [
            w for w in iphone
            if parse_datetime(w.get("startTime")) is not None
            and parse_datetime(w.get("endTime")) is not None
            and overlap(parse_datetime(w["startTime"]), parse_datetime(w["endTime"]), start, effective_end)
        ]
        summary = summarize_iphone_windows(during)
        lines.append(
            f"### Playback Interval {idx}: {fmt_dt(start, tz)} -> {fmt_dt(end, tz) if end else 'session end'}"
        )
        lines.append(
            f"- Asset: `{payload.get('assetName', 'n/a')}`"
        )
        lines.append(
            "- iPhone audio windows: "
            f"total={summary['count']}, withAudio={summary['audio_windows']}, "
            f"quiet={summary['quiet_count']}, silent={summary['silent_count']}, "
            f"polluted={summary['polluted_count']}, disturbance={summary['disturbance_count']}, "
            f"breathingPresent={summary['breathing_present_count']}, breathingSupport≈{summary['breathing_support_count']}."
        )
        lines.append(
            "- Peak audio metrics: "
            f"maxPlaybackLeakage={summary['max_playback_leakage'] if summary['max_playback_leakage'] is not None else 'n/a'}, "
            f"maxDisturbance={summary['max_disturbance'] if summary['max_disturbance'] is not None else 'n/a'}."
        )
        if summary["audio_windows"]:
            quiet_ratio = summary["quiet_count"] / summary["audio_windows"]
            polluted_ratio = summary["polluted_count"] / summary["audio_windows"]
            breathing_ratio = summary["breathing_present_count"] / summary["audio_windows"]
            lines.append(
                f"- Ratios: quiet={quiet_ratio:.2%}, polluted={polluted_ratio:.2%}, breathingPresent={breathing_ratio:.2%}."
            )
        event_lines = route_d_event_lines(data, start, effective_end, tz)
        if event_lines:
            lines.append("- Route D events inside this interval:")
            lines.extend(event_lines)
        else:
            lines.append("- Route D emitted no candidate/confirm/reject events inside this interval.")
        lines.append("")
    return lines


def route_table_section(rows: list[RouteFocus], tz: ZoneInfo) -> list[str]:
    lines = [
        "## ConfirmTime vs 入睡时间（truth onset）",
        "| Route | Method | First confirm at | Stored onset | Confirm - truth (min) | Onset - truth (min) | Confirm - onset (min) | Re-onsets | Stale reuse |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| {row.route_id} | {row.method or 'n/a'} | {fmt_short(row.confirmed_at, tz)} | {fmt_short(row.confirmed_onset, tz)} | {fmt_min(row.confirm_delay_min)} | {fmt_min(row.onset_error_min)} | {fmt_min(row.confirm_gap_min)} | {row.reonset_count} | {row.stale_anchor_reuse_count} |"
        )
    lines.append("")
    return lines


def interpretation_section(data: dict[str, Any], rows: list[RouteFocus], truth: datetime | None, tz: ZoneInfo) -> list[str]:
    session = data.get("session", {})
    start = parse_datetime(session.get("startTime"))
    lines = ["## Interpretation"]
    if truth is not None:
        lines.append(f"- Truth onset: {fmt_dt(truth, tz)}.")
    if start is not None:
        lines.append(f"- Session start: {fmt_dt(start, tz)}.")
    if truth and start:
        delta = (start - truth).total_seconds() / 60.0
        lines.append(f"- Session start minus truth onset: {delta:+.2f} min.")
    best_confirm = [row for row in rows if row.confirm_delay_min is not None]
    if best_confirm:
        best_confirm.sort(key=lambda row: abs(row.confirm_delay_min or 999999))
        winner = best_confirm[0]
        lines.append(
            f"- Smallest |Confirm-truth|: Route {winner.route_id} at {fmt_min(winner.confirm_delay_min)} min."
        )
    best_gap = [row for row in rows if row.confirm_gap_min is not None]
    if best_gap:
        best_gap.sort(key=lambda row: abs(row.confirm_gap_min or 999999))
        winner = best_gap[0]
        lines.append(
            f"- Smallest confirm-onset gap: Route {winner.route_id} at {fmt_min(winner.confirm_gap_min)} min."
        )
    lines.append("")
    return lines


def build_report(path: Path, data: dict[str, Any], tz: ZoneInfo) -> str:
    truth = truth_time(data)
    rows = build_route_focus(data, truth)
    session = data.get("session", {})
    lines = [
        f"# Focus Report: `{path.name}`",
        "",
        "## Session Metadata",
        f"- Session ID: `{session.get('sessionId', 'n/a')}`",
        f"- Start: {fmt_dt(parse_datetime(session.get('startTime')), tz)}",
        f"- End: {fmt_dt(parse_datetime(session.get('endTime')), tz)}",
        f"- Truth onset: {fmt_dt(truth, tz)}",
        f"- Windows: {len(data.get('windows', []))}, events: {len(data.get('events', []))}",
        "",
    ]
    lines.extend(route_table_section(rows, tz))
    lines.extend(interpretation_section(data, rows, truth, tz))
    lines.extend(playback_section(data, tz))
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    tz = ZoneInfo(args.tz)
    data = load_data(args.input)
    report = build_report(args.input, data, tz)
    if args.output_md:
        args.output_md.parent.mkdir(parents=True, exist_ok=True)
        args.output_md.write_text(report, encoding="utf-8")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
