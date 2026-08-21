#!/usr/bin/env bash
# Dry-run: first Cyder open → Preferences-ready (ensureEnvironment mirror).
#
# Mirrors App order: ensure-engine → ensure-graphics → bootstrap-only →
# optional health-check. Uses an isolated CYDER_SUPPORT; does not mutate the
# live Application Support bottle. Wine Mono/Gecko are not prefetched or
# installed during bootstrap (on-demand Wine dialogs / manual scripts).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CYDER_APP:-$ROOT/dist/Cyder.app}"
OUT="${CYDER_MEASURE_OUT:-$ROOT/debug/cyder-first-open-prefs-$(date '+%Y%m%d-%H%M%S')}"

usage() {
  cat <<'EOF'
Usage: bash scripts/cyder-measure-first-open-preferences.sh

Dry-run wall-clock for first-open → Preferences-ready (environment proxy).
Records serial spans under an isolated CYDER_SUPPORT and writes spans.jsonl,
results.json, and timeline.md. Bootstrap substages from bootstrap-timing.jsonl
are merged onto the same axis when present.

Environment:
  CYDER_APP          Path to Cyder.app (default: dist/Cyder.app)
  CYDER_MEASURE_OUT  Output directory
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

RES="$APP/Contents/Resources"
LAUNCHER="$RES/ogom-scripts/cyder_launcher.sh"

[[ -d "$APP" ]] || {
  echo "missing Cyder.app: $APP (build dist/Cyder.app first)" >&2
  exit 1
}
[[ -x "$LAUNCHER" || -f "$LAUNCHER" ]] || {
  echo "missing launcher: $LAUNCHER" >&2
  exit 1
}

ENGINE_SRC=""
for candidate in "$RES"/engine-*.tar.xz "$RES"/engine-*.tar.zst; do
  [[ -f "$candidate" ]] || continue
  ENGINE_SRC="$candidate"
  break
done
[[ -n "$ENGINE_SRC" ]] || {
  echo "missing bundled engine artifact under $RES" >&2
  exit 1
}

mkdir -p "$OUT/first-support" "$OUT/logs"
export CYDER_SUPPORT="$OUT/first-support"
export CYDER_DIAGNOSTIC_VERBOSE=1
export CYDER_DIAGNOSTIC_SESSION_ID="first-open-prefs-measure"
export CYDER_RESULT_FILE="$OUT/bootstrap-result.plist"

echo "== first-open → Preferences dry-run =="
echo "app=$APP"
echo "support=$CYDER_SUPPORT"
echo "out=$OUT"

python3 - "$OUT" "$LAUNCHER" "$ENGINE_SRC" <<'PY'
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

out = Path(sys.argv[1])
launcher = sys.argv[2]
engine_src = sys.argv[3]

spans_path = out / "spans.jsonl"
if spans_path.exists():
    spans_path.unlink()

t0 = time.perf_counter()
spans = []


def elapsed_ms() -> float:
    return round((time.perf_counter() - t0) * 1000, 1)


def emit(name: str, start_ms: float, end_ms: float, status: int, parent=None):
    row = {
        "name": name,
        "start_ms": round(start_ms, 1),
        "end_ms": round(end_ms, 1),
        "duration_ms": round(end_ms - start_ms, 1),
        "status": status,
        "parent": parent,
    }
    spans.append(row)
    with spans_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(
        f"{row['duration_ms']:8.1f} ms  "
        f"[{row['start_ms']:.1f}–{row['end_ms']:.1f}]  "
        f"status={status}  {name}"
        + (f"  parent={parent}" if parent else "")
    )


def run_serial(name, cmd, env=None):
    start = elapsed_ms()
    log_path = out / "logs" / f"{name}.log"
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.run(
            cmd,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            env=env or os.environ.copy(),
        )
    end = elapsed_ms()
    emit(name, start, end, proc.returncode)
    if proc.returncode != 0:
        print(f"FAILED {name}; see {log_path}", file=sys.stderr)
        sys.exit(proc.returncode)
    return proc.returncode


env = os.environ.copy()

run_serial(
    "ensure-engine-only",
    ["bash", launcher, "--engine-src", engine_src, "--ensure-engine-only"],
    env,
)
run_serial(
    "ensure-graphics-only",
    ["bash", launcher, "--ensure-graphics-only"],
    env,
)

bootstrap_env = env.copy()
result_file = Path(bootstrap_env.get("CYDER_RESULT_FILE", str(out / "bootstrap-result.plist")))
if result_file.exists():
    result_file.unlink()
bootstrap_env["CYDER_RESULT_FILE"] = str(result_file)

bootstrap_start = elapsed_ms()
bootstrap_log = out / "logs" / "bootstrap-only.log"
with bootstrap_log.open("w", encoding="utf-8") as log:
    bootstrap_proc = subprocess.run(
        ["bash", launcher, "--engine-src", engine_src, "--bootstrap-only"],
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
        env=bootstrap_env,
    )
bootstrap_end = elapsed_ms()
emit("bootstrap-only", bootstrap_start, bootstrap_end, bootstrap_proc.returncode)

if bootstrap_proc.returncode != 0:
    print(f"FAILED bootstrap-only; see {bootstrap_log}", file=sys.stderr)
    sys.exit(bootstrap_proc.returncode)

health_checked = False
if result_file.exists():
    try:
        with result_file.open("rb") as handle:
            plist = plistlib.load(handle)
        health_checked = str(plist.get("healthChecked", "0")) == "1"
    except Exception as exc:  # noqa: BLE001 — best-effort parse
        print(f"warning: could not parse {result_file}: {exc}", file=sys.stderr)

if not health_checked:
    run_serial(
        "health-check",
        ["bash", launcher, "--engine-src", engine_src, "--health-check"],
        env,
    )
else:
    print("         ms  skip health-check (bootstrap healthChecked=1)")

settings_ms = elapsed_ms()
emit("settings-ready", settings_ms, settings_ms, 0)

# Merge bootstrap substages onto the same axis (serial after wineboot start).
timing_path = Path(env["CYDER_SUPPORT"]) / "Logs" / "bootstrap-timing.jsonl"
substage_rows = []
if timing_path.exists():
    raw = []
    for line in timing_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        stage = row.get("stage")
        elapsed = row.get("elapsed_ms")
        if stage is None or elapsed is None:
            continue
        raw.append(
            {
                "stage": stage,
                "elapsed_ms": float(elapsed),
                "status": int(row.get("status", 0)),
            }
        )

    by_stage = {r["stage"]: r for r in raw}
    wineboot_elapsed = by_stage.get("wineboot", {}).get("elapsed_ms", 0.0)
    artifact_elapsed = by_stage.get("wineboot-artifact-wait", {}).get("elapsed_ms", 0.0)

    wineboot_start = bootstrap_start
    wineboot_end = bootstrap_start + wineboot_elapsed
    placements = []

    if "wineboot" in by_stage:
        placements.append(
            (
                "wineboot",
                wineboot_start,
                wineboot_end,
                by_stage["wineboot"]["status"],
                wineboot_elapsed,
            )
        )
    if "wineboot-artifact-wait" in by_stage:
        art_end = wineboot_end
        art_start = max(wineboot_start, art_end - artifact_elapsed)
        placements.append(
            (
                "wineboot-artifact-wait",
                art_start,
                art_end,
                by_stage["wineboot-artifact-wait"]["status"],
                artifact_elapsed,
            )
        )

    # Stages that may overlap wineboot (e.g. graphics-payload) start at
    # bootstrap_start; remaining stages follow wineboot serially.
    overlapping = {"graphics-payload", "graphics-payload-unpack"}
    last_serial_end = wineboot_end
    for row in raw:
        stage = row["stage"]
        if stage in {"wineboot", "wineboot-artifact-wait"}:
            continue
        elapsed = row["elapsed_ms"]
        if stage in overlapping:
            start = bootstrap_start
        else:
            start = last_serial_end
        end = start + elapsed
        placements.append((stage, start, end, row["status"], elapsed))
        if stage not in overlapping:
            last_serial_end = end

    for stage, start, end, status, elapsed in placements:
        emit(f"bootstrap/{stage}", start, end, status, parent="bootstrap-only")
        substage_rows.append(
            {
                "stage": stage,
                "elapsed_ms": elapsed,
                "status": status,
                "start_ms": round(start, 1),
                "end_ms": round(end, 1),
            }
        )

by_name = {s["name"]: s for s in spans}

results = {
    "app_proxy": "ensureEnvironment → settings-ready (not NSWindow)",
    "phase_b_app_ui": False,
    "settings_ready_ms": by_name["settings-ready"]["end_ms"],
    "health_checked_from_bootstrap": health_checked,
    "bootstrap_substage": substage_rows,
    "spans": spans,
}
(out / "results.json").write_text(
    json.dumps(results, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)


def gantt_id(name: str) -> str:
    return (
        name.replace("/", "_")
        .replace("-", "_")
        .replace(" ", "_")
    )


lines = [
    "# First-open → Preferences timeline",
    "",
    f"- settings-ready: **{results['settings_ready_ms']:.1f} ms** "
    f"(environment proxy; not NSWindow)",
    f"- healthChecked from bootstrap: **{health_checked}**",
    "",
    "```mermaid",
    "gantt",
    "    title First-open Preferences dry-run",
    "    dateFormat X",
    "    axisFormat %s",
]
order = [
    "ensure-engine-only",
    "ensure-graphics-only",
    "bootstrap-only",
    "health-check",
    "settings-ready",
]
seen = set()
for name in order:
    if name in by_name:
        seen.add(name)
        s = by_name[name]
        lines.append(
            f"    {gantt_id(name)} :{int(s['start_ms'])},{int(s['end_ms'])}"
        )
for s in spans:
    if s["name"] in seen or s.get("parent"):
        continue
    lines.append(
        f"    {gantt_id(s['name'])} :{int(s['start_ms'])},{int(s['end_ms'])}"
    )
for row in substage_rows:
    name = f"bootstrap/{row['stage']}"
    lines.append(
        f"    {gantt_id(name)} :{int(row['start_ms'])},{int(row['end_ms'])}"
    )
lines.extend(["```", ""])
(out / "timeline.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {out / 'results.json'}")
print(f"wrote {out / 'timeline.md'}")
PY
