# Session Analysis Tooling

Use `analysis/analyze_session.py` to inspect a session export under `Result/` and render a Markdown report.

## Usage

Analyze the newest session export:

```sh
python3 analysis/analyze_session.py --latest
```

Analyze a specific session file and write a companion report next to it:

```sh
python3 analysis/analyze_session.py \
  --input Result/SleepPOC-8A306B88-0824-4AED-98D3-523292F36640.json \
  --output-md Result/SleepPOC-8A306B88-0824-4AED-98D3-523292F36640.analysis.md
```

Render timestamps in another timezone:

```sh
python3 analysis/analyze_session.py --latest --tz Asia/Shanghai
```

## What It Extracts

- Session metadata, truth onset, and device conditions
- Export mode detection, including current-only exports after schema rollback
- Exported current UI route statuses, plus exported stable statuses when present
- Event-derived latched reference statuses when the export no longer contains stable fields
- First candidate / suspected / confirmed / rejected events for routes `A-F`
- Inferred per-route episodes and re-onset attempts from repeated candidate / confirm / reject cycles
- Split metrics for onset error, detection delay, and onset backfill lead
- Current-vs-reference mismatches, with exported stable view preferred when available and event-derived view used as fallback
- iPhone, Watch, and HealthKit window summaries around truth
- Repo-specific adjustment notes for routes `A-F`

## Notes

- The tool is repo-specific. It assumes the current `SleepPOC-*.json` export schema and route IDs `A-F`.
- If the export is current-only, treat the event-derived latched view as the analysis baseline instead of the final mutable UI state.
- If stable fields exist again later, the tool will automatically prefer them over the event-derived fallback.
- Keep authored investigation notes as `Result/<session>.analysis.md` so the raw export and the human-readable report stay paired.
