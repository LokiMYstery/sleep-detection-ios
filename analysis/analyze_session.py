#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


ROUTES = ("A", "B", "C", "D", "E", "F")
PRIMARY_EVENT_TYPES = {
    "predictionUpdated",
    "candidateWindowEntered",
    "suspectedSleep",
    "confirmedSleep",
    "sleepRejected",
}
TIME_PAYLOAD_KEYS = (
    "predictedTime",
    "candidateTime",
    "putDownTime",
    "time",
    "lastActiveTime",
    "pickupTime",
)


@dataclass
class RouteSummary:
    route_id: str
    current_confidence: str | None
    current_time: datetime | None
    current_available: bool | None
    current_summary: str | None
    reference_origin: str
    stable_confidence: str | None
    stable_time: datetime | None
    stable_available: bool | None
    stable_summary: str | None
    stable_first_candidate_at: datetime | None
    stable_first_confirmed_at: datetime | None
    stable_source_event_type: str | None
    event_count: int
    first_candidate_at: datetime | None
    first_candidate_onset: datetime | None
    first_suspected_at: datetime | None
    first_suspected_onset: datetime | None
    first_confirmed_at: datetime | None
    first_confirmed_onset: datetime | None
    first_confirmed_payload: dict[str, str]
    first_rejected_at: datetime | None
    first_rejected_payload: dict[str, str]
    mismatch_note: str | None
    onset_error_minutes: float | None
    detection_delay_minutes: float | None
    confirm_lead_minutes: float | None
    observations: list[str]


@dataclass
class EpisodeSummary:
    route_id: str
    episode_index: int
    kind: str
    status: str
    start_event_at: datetime | None
    candidate_at: datetime | None
    candidate_onset: datetime | None
    suspected_at: datetime | None
    confirmed_at: datetime | None
    confirmed_onset: datetime | None
    rejected_at: datetime | None
    latest_event_at: datetime | None
    notes: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze a SleepDetectionPOC session JSON and render a Markdown report."
    )
    parser.add_argument(
        "--input",
        type=Path,
        help="Path to a Result/SleepPOC-*.json file.",
    )
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Analyze the newest Result/SleepPOC-*.json by modification time.",
    )
    parser.add_argument(
        "--output-md",
        type=Path,
        help="Write the Markdown report to this path instead of stdout.",
    )
    parser.add_argument(
        "--tz",
        default="Asia/Shanghai",
        help="IANA timezone name used for local timestamps. Default: Asia/Shanghai.",
    )
    parser.add_argument(
        "--context-minutes",
        type=int,
        default=6,
        help="Minutes before and after truth used for source-window summaries. Default: 6.",
    )
    return parser.parse_args()


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def fmt_dual(dt: datetime | None, tz: ZoneInfo, include_seconds: bool = True) -> str:
    if dt is None:
        return "n/a"
    local = dt.astimezone(tz)
    local_fmt = "%Y-%m-%d %H:%M:%S %z" if include_seconds else "%Y-%m-%d %H:%M %z"
    utc_fmt = "%Y-%m-%d %H:%M:%S UTC" if include_seconds else "%Y-%m-%d %H:%M UTC"
    return f"{local.strftime(local_fmt)} / {dt.strftime(utc_fmt)}"


def fmt_short(dt: datetime | None, tz: ZoneInfo) -> str:
    if dt is None:
        return "n/a"
    return dt.astimezone(tz).strftime("%H:%M:%S")


def fmt_minutes(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:+.2f} min"


def safe_median(values: list[float]) -> float | None:
    if not values:
        return None
    return float(statistics.median(values))


def safe_min(values: list[float]) -> float | None:
    return min(values) if values else None


def safe_max(values: list[float]) -> float | None:
    return max(values) if values else None


def format_number(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def latest_session_path() -> Path:
    candidates = list(Path("Result").glob("SleepPOC-*.json"))
    candidates = [path for path in candidates if path.name != "SleepPOC-evaluation.json"]
    if not candidates:
        raise FileNotFoundError("No Result/SleepPOC-*.json files were found.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def choose_input_path(args: argparse.Namespace) -> Path:
    if args.input and args.latest:
        raise SystemExit("Use either --input or --latest, not both.")
    if args.input:
        return args.input
    if args.latest or not args.input:
        return latest_session_path()
    raise AssertionError("unreachable")


def payload_time(payload: dict[str, str]) -> datetime | None:
    for key in TIME_PAYLOAD_KEYS:
        value = payload.get(key)
        parsed = parse_datetime(value)
        if parsed is not None:
            return parsed
    return None


def encode_datetime(value: datetime | None) -> str | None:
    if value is None:
        return None
    iso = value.isoformat()
    return iso[:-6] + "Z" if iso.endswith("+00:00") else iso


def route_events(data: dict[str, Any], route_id: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for event in data["events"]:
        if event.get("routeId") != route_id:
            continue
        if event.get("eventType") not in PRIMARY_EVENT_TYPES and not str(event.get("eventType", "")).startswith("custom."):
            continue
        items.append(event)
    items.sort(key=lambda item: parse_datetime(item["timestamp"]) or datetime.min)
    return items


def infer_episodes(route_id: str, events: list[dict[str, Any]]) -> list[EpisodeSummary]:
    episodes: list[EpisodeSummary] = []
    active: EpisodeSummary | None = None

    def new_episode(ts: datetime | None, onset: datetime | None, status: str) -> EpisodeSummary:
        return EpisodeSummary(
            route_id=route_id,
            episode_index=0,
            kind="primary",
            status=status,
            start_event_at=ts,
            candidate_at=ts if status in {"candidate", "candidate_only"} else None,
            candidate_onset=onset if status in {"candidate", "candidate_only"} else None,
            suspected_at=None,
            confirmed_at=None,
            confirmed_onset=None,
            rejected_at=None,
            latest_event_at=ts,
            notes=[],
        )

    def close_active() -> None:
        nonlocal active
        if active is None:
            return
        if active.rejected_at is not None and active.confirmed_at is not None:
            active.status = "confirmed_then_rejected"
        elif active.rejected_at is not None:
            active.status = "rejected"
        elif active.confirmed_at is not None:
            active.status = "confirmed"
        elif active.candidate_at is not None:
            active.status = "candidate_only"
        else:
            active.status = "partial"
        episodes.append(active)
        active = None

    for event in events:
        event_type = event["eventType"]
        if event_type not in PRIMARY_EVENT_TYPES:
            continue

        ts = parse_datetime(event["timestamp"])
        onset = payload_time(event.get("payload", {}))

        if event_type == "predictionUpdated":
            continue

        if event_type == "candidateWindowEntered":
            if active is not None:
                close_active()
            active = new_episode(ts, onset, "candidate")
            continue

        if event_type == "suspectedSleep":
            if active is None:
                active = new_episode(ts, onset, "candidate")
            if active.suspected_at is None:
                active.suspected_at = ts
            if active.candidate_onset is None and onset is not None:
                active.candidate_onset = onset
            active.latest_event_at = ts
            continue

        if event_type == "confirmedSleep":
            if active is None:
                active = new_episode(ts, onset, "partial")
            if active.confirmed_at is None:
                active.confirmed_at = ts
            if active.confirmed_onset is None:
                active.confirmed_onset = onset
            if active.candidate_onset is None and onset is not None:
                active.candidate_onset = onset
            active.latest_event_at = ts
            continue

        if event_type == "sleepRejected":
            if active is None:
                active = new_episode(ts, onset, "partial")
            active.rejected_at = ts
            active.latest_event_at = ts
            close_active()
            continue

    close_active()

    for index, episode in enumerate(episodes, start=1):
        episode.episode_index = index
        episode.kind = "primary" if index == 1 else "re-onset"
        if episode.confirmed_at and episode.confirmed_onset:
            lead_minutes = (episode.confirmed_at - episode.confirmed_onset).total_seconds() / 60.0
            if lead_minutes >= 2:
                episode.notes.append(
                    f"stored onset leads confirmation by {lead_minutes:.2f} min"
                )
        if index > 1:
            previous = episodes[index - 2]
            previous_onset = previous.confirmed_onset or previous.candidate_onset
            current_onset = episode.confirmed_onset or episode.candidate_onset
            if previous_onset and current_onset:
                delta_seconds = abs((current_onset - previous_onset).total_seconds())
                if delta_seconds <= 60:
                    episode.notes.append("stored onset repeats the previous episode, which suggests stale anchor reuse or a reset artifact")

    return episodes


def first_event(
    events: list[dict[str, Any]],
    event_type: str,
) -> tuple[datetime | None, datetime | None, dict[str, str]]:
    for event in events:
        if event["eventType"] != event_type:
            continue
        timestamp = parse_datetime(event["timestamp"])
        payload = event.get("payload", {})
        return timestamp, payload_time(payload), payload
    return None, None, {}


def first_rejection_after(
    events: list[dict[str, Any]],
    after: datetime | None,
) -> tuple[datetime | None, dict[str, str]]:
    for event in events:
        if event["eventType"] != "sleepRejected":
            continue
        timestamp = parse_datetime(event["timestamp"])
        if after is None or (timestamp is not None and timestamp > after):
            return timestamp, event.get("payload", {})
    return None, {}


def top_prediction_map(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["routeId"]: item for item in data["predictions"]}


def current_status_map(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    diagnostics = data.get("diagnostics") or {}
    route_statuses = diagnostics.get("routeStatuses")
    if route_statuses:
        return {item["routeId"]: item for item in route_statuses}
    return top_prediction_map(data)


def exported_stable_status_map(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    diagnostics = data.get("diagnostics") or {}
    latched_statuses = diagnostics.get("latchedRouteStatuses")
    if latched_statuses:
        return {item["routeId"]: item for item in latched_statuses}

    latched_predictions = data.get("latchedPredictions") or []
    return {item["routeId"]: item for item in latched_predictions}


def event_derived_status_map(
    data: dict[str, Any],
    current_statuses: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    derived: dict[str, dict[str, Any]] = {}

    for route_id in ROUTES:
        events = route_events(data, route_id)
        candidate_at, candidate_onset, _ = first_event(events, "candidateWindowEntered")
        suspected_at, suspected_onset, _ = first_event(events, "suspectedSleep")
        confirmed_at, confirmed_onset, confirmed_payload = first_event(events, "confirmedSleep")
        current = current_statuses.get(route_id, {})

        if confirmed_at is not None or confirmed_onset is not None:
            method = confirmed_payload.get("method")
            summary = "Inferred from first confirmedSleep event"
            if method:
                summary += f" (`{method}`)"
            derived[route_id] = {
                "routeId": route_id,
                "confidence": "confirmed",
                "isAvailable": current.get("isAvailable"),
                "predictedSleepOnset": encode_datetime(confirmed_onset or suspected_onset or candidate_onset or confirmed_at),
                "lastUpdated": encode_datetime(confirmed_at or confirmed_onset),
                "evidenceSummary": summary,
                "firstCandidateAt": encode_datetime(candidate_at),
                "firstConfirmedAt": encode_datetime(confirmed_at),
                "sourceEventType": "confirmedSleep",
            }
            continue

        if suspected_at is not None or suspected_onset is not None:
            derived[route_id] = {
                "routeId": route_id,
                "confidence": "suspected",
                "isAvailable": current.get("isAvailable"),
                "predictedSleepOnset": encode_datetime(suspected_onset or candidate_onset or suspected_at),
                "lastUpdated": encode_datetime(suspected_at or suspected_onset),
                "evidenceSummary": "Inferred from first suspectedSleep event",
                "firstCandidateAt": encode_datetime(candidate_at),
                "firstConfirmedAt": None,
                "sourceEventType": "suspectedSleep",
            }
            continue

        if candidate_at is not None or candidate_onset is not None:
            derived[route_id] = {
                "routeId": route_id,
                "confidence": "candidate",
                "isAvailable": current.get("isAvailable"),
                "predictedSleepOnset": encode_datetime(candidate_onset or candidate_at),
                "lastUpdated": encode_datetime(candidate_at or candidate_onset),
                "evidenceSummary": "Inferred from first candidateWindowEntered event",
                "firstCandidateAt": encode_datetime(candidate_at),
                "firstConfirmedAt": None,
                "sourceEventType": "candidateWindowEntered",
            }

    return derived


def export_mode(data: dict[str, Any]) -> str:
    diagnostics = data.get("diagnostics") or {}
    if diagnostics.get("latchedRouteStatuses"):
        return "stable+current (diagnostics.latchedRouteStatuses)"
    if data.get("latchedPredictions"):
        return "stable+current (latchedPredictions)"
    if diagnostics.get("routeStatuses"):
        return "current-only (diagnostics.routeStatuses)"
    if data.get("predictions"):
        return "current-only (predictions)"
    return "events-only"


def extract_custom_event_payload(
    events: list[dict[str, Any]],
    event_type: str,
) -> dict[str, str] | None:
    for event in events:
        if event["eventType"] == event_type:
            return event.get("payload", {})
    return None


def window_context(
    data: dict[str, Any],
    truth: datetime | None,
    minutes: int,
) -> dict[str, dict[str, Any]]:
    if truth is None:
        return {"iphone": {}, "watch": {}, "healthKit": {}}

    start = truth - timedelta(minutes=minutes)
    end = truth + timedelta(minutes=minutes)
    iphone_windows: list[dict[str, Any]] = []
    watch_windows: list[dict[str, Any]] = []
    hk_windows: list[dict[str, Any]] = []

    for window in data["windows"]:
        end_time = parse_datetime(window["endTime"])
        if end_time is None or end_time < start or end_time > end:
            continue
        source = window["source"]
        if source == "iphone":
            iphone_windows.append(window)
        elif source == "watch":
            watch_windows.append(window)
        elif source == "healthKit":
            hk_windows.append(window)

    iphone_motion = [window.get("motion") or {} for window in iphone_windows if window.get("motion")]
    iphone_audio = [window.get("audio") or {} for window in iphone_windows if window.get("audio")]
    iphone_interaction = [window.get("interaction") or {} for window in iphone_windows if window.get("interaction")]

    watch_features = [window.get("watch") or {} for window in watch_windows if window.get("watch")]
    hk_features = [window.get("physiology") or {} for window in hk_windows if window.get("physiology")]

    iphone_summary = {
        "count": len(iphone_windows),
        "accel_median": safe_median([item.get("accelRMS", 0.0) for item in iphone_motion]),
        "still_ratio_median": safe_median([item.get("stillRatio", 0.0) for item in iphone_motion]),
        "inactive_min_min": safe_min([(item.get("timeSinceLastInteraction", 0.0) / 60.0) for item in iphone_interaction]),
        "inactive_min_max": safe_max([(item.get("timeSinceLastInteraction", 0.0) / 60.0) for item in iphone_interaction]),
        "silent_ratio": (
            sum(1 for item in iphone_audio if item.get("isSilent")) / len(iphone_audio)
            if iphone_audio else None
        ),
    }

    watch_summary = {
        "count": len(watch_windows),
        "hr_min": safe_min([item["heartRate"] for item in watch_features if item.get("heartRate") is not None]),
        "hr_median": safe_median([item["heartRate"] for item in watch_features if item.get("heartRate") is not None]),
        "hr_max": safe_max([item["heartRate"] for item in watch_features if item.get("heartRate") is not None]),
        "median_rms": safe_median([item.get("wristAccelRMS", 0.0) for item in watch_features]),
        "max_still_seconds": safe_max([item.get("wristStillDuration", 0.0) for item in watch_features]),
    }

    hk_hr_values = [item["heartRate"] for item in hk_features if item.get("heartRate") is not None]
    hk_summary = {
        "count": len(hk_windows),
        "hr_min": safe_min(hk_hr_values),
        "hr_median": safe_median(hk_hr_values),
        "hr_max": safe_max(hk_hr_values),
        "backfilled_ratio": (
            sum(1 for item in hk_features if item.get("isBackfilled")) / len(hk_features)
            if hk_features else None
        ),
        "first_hr_time": parse_datetime(hk_windows[0]["endTime"]) if hk_windows else None,
        "last_hr_time": parse_datetime(hk_windows[-1]["endTime"]) if hk_windows else None,
    }

    return {
        "iphone": iphone_summary,
        "watch": watch_summary,
        "healthKit": hk_summary,
    }


def route_observations(
    route_id: str,
    summary: RouteSummary,
    route_events_for_id: list[dict[str, Any]],
    context: dict[str, dict[str, Any]],
) -> list[str]:
    notes: list[str] = []

    if summary.first_confirmed_at and summary.first_confirmed_onset and summary.confirm_lead_minutes and summary.confirm_lead_minutes >= 2:
        notes.append(
            f"Confirmed at {fmt_minutes(summary.confirm_lead_minutes)} after the stored onset, so onset backfill and confirmation timing should be evaluated separately."
        )

    if summary.first_confirmed_at and summary.mismatch_note:
        notes.append(summary.mismatch_note)

    if route_id == "A" and summary.first_confirmed_at and summary.current_confidence != "confirmed":
        notes.append("Route A confirmed once, then later fell back to its baseline timer view instead of latching the confirmed onset.")

    if route_id == "B" and summary.first_rejected_at:
        reason = summary.first_rejected_payload.get("reason", "unknown")
        notes.append(f"Route B invalidated its anchor after confirmation due to `{reason}`, so wake/pickup handling is currently overwriting the earlier onset.")

    if route_id == "C" and summary.confirm_lead_minutes and summary.confirm_lead_minutes >= 4:
        notes.append("Route C's confirmation timing is closer to truth than its stored onset, which suggests the route should learn a per-user onset offset instead of backfilling to the full still run start.")

    if route_id == "D":
        breathing = summary.first_confirmed_payload.get("breathingRate")
        if breathing == "none":
            notes.append("The first confirmation did not include positive breathing evidence, so this looks like a quiet-only early confirmation rather than a rich multimodal match.")
        if context["iphone"].get("silent_ratio") == 1.0 and summary.first_confirmed_onset:
            notes.append("Near truth, the iPhone windows were uniformly silent and still, which currently lets quiet-only windows dominate this route.")

    if route_id == "E":
        watch_context = context["watch"]
        if summary.first_confirmed_at is None:
            if (watch_context.get("median_rms") or 0) > 0.5 and (watch_context.get("max_still_seconds") or 0) == 0:
                notes.append("Watch RMS stayed near 1g with zero still duration, which strongly suggests the exported watch motion includes gravity and does not match Route E's stillness thresholds.")
            else:
                notes.append("No Route E candidate or confirmed events were emitted in this session.")

    if route_id == "F":
        profile = extract_custom_event_payload(route_events_for_id, "custom.routeFProfileResolved")
        if profile:
            notes.append(
                "Route F profile resolved to "
                f"`readiness={profile.get('readiness', 'n/a')}`, "
                f"`profile={profile.get('profile', 'n/a')}`, "
                f"`eveningHRMedian={profile.get('eveningHRMedian', 'n/a')}`, "
                f"`nightLowHRMedian={profile.get('nightLowHRMedian', 'n/a')}`."
            )
        if (context["healthKit"].get("backfilled_ratio") or 0) > 0.5:
            notes.append("Most truth-window HealthKit samples were backfilled, so this route's onset estimate is usable, but its real-time confirmation lag is much longer.")

    return notes


def summarize_route(
    route_id: str,
    data: dict[str, Any],
    truth: datetime | None,
    current_statuses: dict[str, dict[str, Any]],
    exported_stable_statuses: dict[str, dict[str, Any]],
    derived_statuses: dict[str, dict[str, Any]],
    context: dict[str, dict[str, Any]],
) -> RouteSummary:
    events = route_events(data, route_id)
    current = current_statuses.get(route_id, {})
    reference_origin = "missing"
    reference = exported_stable_statuses.get(route_id)
    if reference:
        reference_origin = "exported_stable"
    else:
        reference = derived_statuses.get(route_id)
        if reference:
            reference_origin = "event_derived"
        else:
            reference = {}

    current_confidence = current.get("confidence")
    current_time = parse_datetime(current.get("predictedSleepOnset"))
    current_available = current.get("isAvailable")
    current_summary = current.get("evidenceSummary")
    stable_confidence = reference.get("confidence")
    stable_time = parse_datetime(reference.get("predictedSleepOnset"))
    stable_available = reference.get("isAvailable")
    stable_summary = reference.get("evidenceSummary")
    stable_first_candidate_at = parse_datetime(reference.get("firstCandidateAt"))
    stable_first_confirmed_at = parse_datetime(reference.get("firstConfirmedAt"))
    stable_source_event_type = reference.get("sourceEventType")

    candidate_at, candidate_onset, _ = first_event(events, "candidateWindowEntered")
    suspected_at, suspected_onset, _ = first_event(events, "suspectedSleep")
    confirmed_at, confirmed_onset, confirmed_payload = first_event(events, "confirmedSleep")
    rejected_at, rejected_payload = first_rejection_after(events, confirmed_at)

    onset_error_minutes = None
    detection_delay_minutes = None
    confirm_lead_minutes = None
    if truth is not None and confirmed_onset is not None:
        onset_error_minutes = (confirmed_onset - truth).total_seconds() / 60.0
    if truth is not None and confirmed_at is not None:
        detection_delay_minutes = (confirmed_at - truth).total_seconds() / 60.0
    if confirmed_at is not None and confirmed_onset is not None:
        confirm_lead_minutes = (confirmed_at - confirmed_onset).total_seconds() / 60.0

    mismatch_note = None
    if reference_origin == "exported_stable" and stable_confidence is not None and (
        current_confidence != stable_confidence
        or current_time != stable_time
        or current_available != stable_available
    ):
        mismatch_note = (
            "Current UI status differs from the exported stable/latched status, "
            "so automation and offline evaluation should prefer the stable view."
        )
    elif reference_origin == "event_derived" and stable_confidence is not None and (
        current_confidence != stable_confidence
        or current_time != stable_time
    ):
        mismatch_note = (
            "This export only contains mutable current route status. "
            "The latched reference view was reconstructed from the event stream and differs from the exported current view."
        )
    elif reference_origin == "exported_stable" and confirmed_onset is not None and stable_time is not None:
        delta = abs((stable_time - confirmed_onset).total_seconds()) / 60.0
        if delta >= 1:
            mismatch_note = (
                "Stable predictedSleepOnset differs materially from the first confirmed onset in the event stream, "
                "so the route likely has a backfill or anchor interpretation gap."
            )

    summary = RouteSummary(
        route_id=route_id,
        current_confidence=current_confidence,
        current_time=current_time,
        current_available=current_available,
        current_summary=current_summary,
        reference_origin=reference_origin,
        stable_confidence=stable_confidence,
        stable_time=stable_time,
        stable_available=stable_available,
        stable_summary=stable_summary,
        stable_first_candidate_at=stable_first_candidate_at,
        stable_first_confirmed_at=stable_first_confirmed_at,
        stable_source_event_type=stable_source_event_type,
        event_count=len(events),
        first_candidate_at=candidate_at,
        first_candidate_onset=candidate_onset,
        first_suspected_at=suspected_at,
        first_suspected_onset=suspected_onset,
        first_confirmed_at=confirmed_at,
        first_confirmed_onset=confirmed_onset,
        first_confirmed_payload=confirmed_payload,
        first_rejected_at=rejected_at,
        first_rejected_payload=rejected_payload,
        mismatch_note=mismatch_note,
        onset_error_minutes=onset_error_minutes,
        detection_delay_minutes=detection_delay_minutes,
        confirm_lead_minutes=confirm_lead_minutes,
        observations=[],
    )
    summary.observations = route_observations(route_id, summary, events, context)
    return summary


def session_overview(
    data: dict[str, Any],
    path: Path,
    tz: ZoneInfo,
    schema_mode: str,
    current_count: int,
    exported_stable_count: int,
    derived_count: int,
) -> list[str]:
    session = data["session"]
    truth = data.get("truth") or {}
    device = session.get("deviceCondition", {})
    lines = [
        f"# Session Analysis: `{path.name}`",
        "",
        "## Session Overview",
        f"- Session ID: `{session['sessionId']}`",
        f"- Input file: `{path}`",
        f"- Start: {fmt_dual(parse_datetime(session.get('startTime')), tz)}",
        f"- End: {fmt_dual(parse_datetime(session.get('endTime')), tz)}",
        f"- HealthKit truth onset: {fmt_dual(parse_datetime(truth.get('healthKitSleepOnset')), tz)}",
        f"- Prior level: `{session.get('priorLevel', 'n/a')}`",
        f"- Phone placement: `{session.get('phonePlacement', 'n/a')}`",
        (
            "- Device condition: "
            f"watch={device.get('hasWatch')}, "
            f"watchReachable={device.get('watchReachable')}, "
            f"healthKit={device.get('hasHealthKitAccess')}, "
            f"microphone={device.get('hasMicrophoneAccess')}, "
            f"motion={device.get('hasMotionAccess')}"
        ),
        f"- Export mode: `{schema_mode}`",
        (
            "- Export counts: "
            f"windows={len(data['windows'])}, "
            f"events={len(data['events'])}, "
            f"currentStatuses={current_count}, "
            f"exportedStableStatuses={exported_stable_count}, "
            f"eventDerivedStatuses={derived_count}"
        ),
        "",
    ]
    return lines


def key_findings(route_summaries: list[RouteSummary], tz: ZoneInfo) -> list[str]:
    lines = ["## Key Findings"]
    ever_confirmed = [summary.route_id for summary in route_summaries if summary.first_confirmed_onset is not None]
    if ever_confirmed:
        lines.append(
            "- Routes that emitted a confirmed onset at least once: "
            + ", ".join(f"`{route_id}`" for route_id in ever_confirmed)
            + "."
        )
    else:
        lines.append("- No route emitted a confirmed onset in the event stream.")

    exported_stable_present = [
        summary.route_id
        for summary in route_summaries
        if summary.reference_origin == "exported_stable"
    ]
    if exported_stable_present:
        lines.append(
            "- Stable exported statuses are available for: "
            + ", ".join(f"`{route_id}`" for route_id in exported_stable_present)
            + "."
        )

    derived_present = [
        summary.route_id
        for summary in route_summaries
        if summary.reference_origin == "event_derived"
    ]
    if derived_present:
        lines.append(
            "- This export does not contain a stable/latched route view for: "
            + ", ".join(f"`{route_id}`" for route_id in derived_present)
            + ". The report reconstructs a latched reference view from the event stream."
        )

    exported_mismatches = [
        summary.route_id
        for summary in route_summaries
        if summary.reference_origin == "exported_stable" and summary.mismatch_note
    ]
    if exported_mismatches:
        lines.append(
            "- Current-vs-exported-stable mismatches were detected for: "
            + ", ".join(f"`{route_id}`" for route_id in exported_mismatches)
            + ". Offline evaluation and auto-stop policy should prefer the stable view instead of the mutable UI state."
        )

    derived_mismatches = [
        summary.route_id
        for summary in route_summaries
        if summary.reference_origin == "event_derived" and summary.mismatch_note
    ]
    if derived_mismatches:
        lines.append(
            "- Current-vs-event-derived mismatches were detected for: "
            + ", ".join(f"`{route_id}`" for route_id in derived_mismatches)
            + ". Because this schema is current-only, offline evaluation should prefer the event-derived latched view over the mutable final UI state."
        )

    best = [
        summary for summary in route_summaries
        if summary.onset_error_minutes is not None
    ]
    if best:
        best.sort(key=lambda summary: abs(summary.onset_error_minutes or 10_000))
        winner = best[0]
        lines.append(
            f"- Smallest first-confirmed onset error: Route `{winner.route_id}` at "
            f"{fmt_minutes(winner.onset_error_minutes)} relative to truth "
            f"(stored onset {fmt_short(winner.first_confirmed_onset, tz)})."
        )

    lines.append("")
    return lines


def context_section(context: dict[str, dict[str, Any]], tz: ZoneInfo) -> list[str]:
    iphone = context["iphone"]
    watch = context["watch"]
    healthkit = context["healthKit"]

    lines = [
        "## Sensor Context Around Truth",
        "- iPhone windows: "
        f"count={iphone.get('count', 0)}, "
        f"accel median={format_number(iphone.get('accel_median'))}, "
        f"stillRatio median={format_number(iphone.get('still_ratio_median'))}, "
        f"inactive range={format_number(iphone.get('inactive_min_min'), 2)}-"
        f"{format_number(iphone.get('inactive_min_max'), 2)} min, "
        f"silent ratio={format_number(iphone.get('silent_ratio'), 2)}.",
        "- Watch windows: "
        f"count={watch.get('count', 0)}, "
        f"HR min/median/max={format_number(watch.get('hr_min'), 1)}/"
        f"{format_number(watch.get('hr_median'), 1)}/"
        f"{format_number(watch.get('hr_max'), 1)}, "
        f"RMS median={format_number(watch.get('median_rms'))}, "
        f"max still={format_number(watch.get('max_still_seconds'), 1)} s.",
        "- HealthKit windows: "
        f"count={healthkit.get('count', 0)}, "
        f"HR min/median/max={format_number(healthkit.get('hr_min'), 1)}/"
        f"{format_number(healthkit.get('hr_median'), 1)}/"
        f"{format_number(healthkit.get('hr_max'), 1)}, "
        f"backfilled ratio={format_number(healthkit.get('backfilled_ratio'), 2)}, "
        f"first/last sample={fmt_dual(healthkit.get('first_hr_time'), tz)} -> "
        f"{fmt_dual(healthkit.get('last_hr_time'), tz)}.",
        "",
    ]
    return lines


def route_sections(route_summaries: list[RouteSummary], tz: ZoneInfo) -> list[str]:
    lines = ["## Route-by-Route"]
    for summary in route_summaries:
        lines.append(f"### Route {summary.route_id}")
        lines.append(
            "- Current UI view: "
            f"confidence=`{summary.current_confidence or 'n/a'}`, "
            f"available={summary.current_available}, "
            f"predictedSleepOnset={fmt_dual(summary.current_time, tz)}, "
            f"summary={summary.current_summary or 'n/a'}"
        )
        if summary.reference_origin == "exported_stable":
            lines.append(
                "- Stable exported view: "
                f"confidence=`{summary.stable_confidence or 'n/a'}`, "
                f"available={summary.stable_available}, "
                f"predictedSleepOnset={fmt_dual(summary.stable_time, tz)}, "
                f"firstCandidateAt={fmt_dual(summary.stable_first_candidate_at, tz)}, "
                f"firstConfirmedAt={fmt_dual(summary.stable_first_confirmed_at, tz)}, "
                f"sourceEventType={summary.stable_source_event_type or 'n/a'}, "
                f"summary={summary.stable_summary or 'n/a'}"
            )
        elif summary.reference_origin == "event_derived":
            lines.append(
                "- Event-derived latched view: "
                f"confidence=`{summary.stable_confidence or 'n/a'}`, "
                f"predictedSleepOnset={fmt_dual(summary.stable_time, tz)}, "
                f"firstCandidateAt={fmt_dual(summary.stable_first_candidate_at, tz)}, "
                f"firstConfirmedAt={fmt_dual(summary.stable_first_confirmed_at, tz)}, "
                f"sourceEventType={summary.stable_source_event_type or 'n/a'}, "
                f"summary={summary.stable_summary or 'n/a'}"
            )
        else:
            lines.append(
                "- Reference view: unavailable because this export has no stable route status and the event stream never reached candidate/suspected/confirmed for this route."
            )
        lines.append(
            "- First route milestones: "
            f"candidate={fmt_dual(summary.first_candidate_onset, tz)}, "
            f"suspected={fmt_dual(summary.first_suspected_onset, tz)}, "
            f"confirmed onset={fmt_dual(summary.first_confirmed_onset, tz)}, "
            f"confirmed event time={fmt_dual(summary.first_confirmed_at, tz)}"
        )
        lines.append(
            "- Error split: "
            f"onset error={fmt_minutes(summary.onset_error_minutes)}, "
            f"detection delay={fmt_minutes(summary.detection_delay_minutes)}, "
            f"confirm lead={fmt_minutes(summary.confirm_lead_minutes)}"
        )
        if summary.first_rejected_at is not None:
            lines.append(
                "- First rejection after confirmation: "
                f"{fmt_dual(summary.first_rejected_at, tz)} "
                f"with payload {json.dumps(summary.first_rejected_payload, ensure_ascii=False, sort_keys=True)}"
            )
        if summary.first_confirmed_payload:
            lines.append(
                "- First confirmation payload: "
                + json.dumps(summary.first_confirmed_payload, ensure_ascii=False, sort_keys=True)
            )
        if summary.observations:
            for note in summary.observations:
                lines.append(f"- Observation: {note}")
        else:
            lines.append("- Observation: no special route-specific note.")
        lines.append("")
    return lines


def episode_sections(
    episode_map: dict[str, list[EpisodeSummary]],
    tz: ZoneInfo,
) -> list[str]:
    lines = ["## Inferred Episodes / Re-Onsets"]
    has_any = False
    for route_id in ROUTES:
        episodes = episode_map.get(route_id, [])
        if not episodes:
            continue
        has_any = True
        reonset_count = max(0, len(episodes) - 1)
        lines.append(
            f"### Route {route_id}: {len(episodes)} inferred episode(s), {reonset_count} re-onset attempt(s)"
        )
        for episode in episodes:
            lines.append(
                "- "
                f"{episode.kind} #{episode.episode_index}: "
                f"status=`{episode.status}`, "
                f"candidateAt={fmt_dual(episode.candidate_at, tz)}, "
                f"candidateOnset={fmt_dual(episode.candidate_onset, tz)}, "
                f"confirmedAt={fmt_dual(episode.confirmed_at, tz)}, "
                f"estimatedOnset={fmt_dual(episode.confirmed_onset, tz)}, "
                f"rejectedAt={fmt_dual(episode.rejected_at, tz)}"
            )
            for note in episode.notes:
                lines.append(f"- Episode note: {note}")
        lines.append("")

    if not has_any:
        lines.append("- No candidate/confirmed episode structure could be inferred from the event stream.")
        lines.append("")
    return lines


def recommendation_section(route_summaries: list[RouteSummary]) -> list[str]:
    lines = ["## Adjustment Directions"]
    recommended: dict[str, str] = {
        "A": "Keep Route A as a prior-only baseline, but latch its first confirmed onset so later wake interactions do not revert the stored answer.",
        "B": "Re-anchor Route B on the latest put-down after pickup/wake instead of reusing an old interaction time, then keep the first valid confirmed onset latched.",
        "C": "Treat Route C's onset offset as a learnable per-user parameter so the route no longer backfills all the way to the first still window.",
        "D": "Separate quiet-only evidence from positive audio evidence. Quiet-only windows should need a longer duration or lower confidence than breathing/snore-supported windows.",
        "E": "Fix watch motion normalization before retuning thresholds. The current watch RMS appears to include gravity, so Route E thresholds are not operating on the intended signal.",
        "F": "Separate realtime confidence from backfilled confidence, and learn a user-specific onset offset from the first sustained low-HR window instead of using the earliest qualifying sample directly.",
    }
    for route_id in ROUTES:
        lines.append(f"- Route {route_id}: {recommended[route_id]}")
    lines.append("")
    return lines


def build_report(path: Path, data: dict[str, Any], tz: ZoneInfo, context_minutes: int) -> str:
    truth = parse_datetime((data.get("truth") or {}).get("healthKitSleepOnset"))
    current_statuses = current_status_map(data)
    exported_stable_statuses = exported_stable_status_map(data)
    derived_statuses = event_derived_status_map(data, current_statuses)
    schema_mode = export_mode(data)
    context = window_context(data, truth, context_minutes)
    episode_map = {
        route_id: infer_episodes(route_id, route_events(data, route_id))
        for route_id in ROUTES
    }
    route_summaries = [
        summarize_route(
            route_id,
            data,
            truth,
            current_statuses,
            exported_stable_statuses,
            derived_statuses,
            context,
        )
        for route_id in ROUTES
    ]

    sections: list[str] = []
    sections.extend(
        session_overview(
            data,
            path,
            tz,
            schema_mode,
            len(current_statuses),
            len(exported_stable_statuses),
            len(derived_statuses),
        )
    )
    sections.extend(key_findings(route_summaries, tz))
    sections.extend(context_section(context, tz))
    sections.extend(route_sections(route_summaries, tz))
    sections.extend(episode_sections(episode_map, tz))
    sections.extend(recommendation_section(route_summaries))
    return "\n".join(sections).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    input_path = choose_input_path(args)
    tz = ZoneInfo(args.tz)

    with input_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    report = build_report(input_path, data, tz, args.context_minutes)

    if args.output_md:
        args.output_md.parent.mkdir(parents=True, exist_ok=True)
        args.output_md.write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
