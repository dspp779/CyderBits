#!/usr/bin/env bash
# Time Cyder launcher stages without mutating the live bottle.
#
# Default: subsequent-open + EXE/URI prechecks against the installed engine.
# --first-prefix: wineboot a throwaway prefix (reuses ~/.cyder/runtime engine).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CYDER_APP:-$ROOT/dist/Cyder.app}"
RES="$APP/Contents/Resources"
LAUNCHER="$RES/ogom-scripts/cyder_launcher.sh"
LIVE_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
OUT="${CYDER_MEASURE_OUT:-$ROOT/debug/cyder-startup-measure-$(date '+%Y%m%d-%H%M%S')}"
RUN_FIRST_PREFIX=0
ROUNDS=2

usage() {
  cat <<'EOF'
Usage: bash scripts/cyder-measure-startup.sh [--first-prefix] [--rounds N]

Measures launcher-stage wall time for later startup optimization.
Does not extract a new engine tarball and does not rebuild the live bottle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-prefix) RUN_FIRST_PREFIX=1; shift ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -x "$LAUNCHER" ]] || {
  echo "missing launcher: $LAUNCHER (build dist/Cyder.app first)" >&2
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

mkdir -p "$OUT"

time_cmd() {
  local name="$1"
  shift
  python3 - "$OUT" "$name" "$@" <<'PY'
import json, subprocess, sys, time
from pathlib import Path

out_dir, name, *cmd = sys.argv[1:]
t0 = time.perf_counter()
proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
elapsed_ms = (time.perf_counter() - t0) * 1000
log_path = Path(out_dir) / f"{name}.log"
log_path.write_text(proc.stdout)
record = {
    "name": name,
    "elapsed_ms": round(elapsed_ms, 1),
    "status": proc.returncode,
    "cmd": cmd,
    "log": str(log_path),
}
records_path = Path(out_dir) / "records.jsonl"
with records_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False) + "\n")
print(f"{elapsed_ms:8.1f} ms  status={proc.returncode}  {name}")
sys.exit(0 if proc.returncode == 0 else proc.returncode)
PY
}

export CYDER_DIAGNOSTIC_VERBOSE=1
export CYDER_DIAGNOSTIC_SESSION_ID="measure-startup"

echo "== subsequent open (live support, engine already installed) =="
export CYDER_SUPPORT="$LIVE_SUPPORT"
for i in $(seq 1 "$ROUNDS"); do
  time_cmd "subsequent-ensure-engine-$i" \
    bash "$LAUNCHER" --engine-src "$ENGINE_SRC" --ensure-engine-only
  time_cmd "subsequent-ensure-graphics-$i" \
    bash "$LAUNCHER" --ensure-graphics-only
  time_cmd "subsequent-health-check-$i" \
    bash "$LAUNCHER" --engine-src "$ENGINE_SRC" --health-check || true
done

echo "== EXE / URI prechecks =="
time_cmd "exe-engine-ready" bash -c '
  source "$1/ogom-scripts/cyder-common.sh"
  cyder_init_paths "$1"
  if cyder_engine_is_ready_for_launch; then echo ready; else echo not-ready; exit 1; fi
' _ "$RES"
time_cmd "exe-marker-stat" bash -c '
  test -x "$HOME/.cyder/runtime/Engines/wine-x86_64/bin/wine"
  test -f "$1/bottles/shared/.cyder-bootstrap-v1"
  test -f "$1/bottles/shared/system.reg"
' _ "$LIVE_SUPPORT"
URI_PREFIX="$LIVE_SUPPORT/bottles/shared"
if [[ -f "$URI_PREFIX/system.reg" ]]; then
  time_cmd "uri-scan-live" \
    bash "$LAUNCHER" --scan-uri-handlers "$URI_PREFIX" gamaniagames || true
fi
time_cmd "uri-scan-fixture" \
  bash "$ROOT/scripts/cyder_launcher.sh" --scan-uri-handlers \
    "$ROOT/tests/fixtures/url-handler/gamaniagames" gamaniagames

if [[ "$RUN_FIRST_PREFIX" -eq 1 ]]; then
  echo "== first prefix (isolated CYDER_SUPPORT, reused engine) =="
  FIRST_SUPPORT="$OUT/first-support"
  mkdir -p "$FIRST_SUPPORT"
  export CYDER_SUPPORT="$FIRST_SUPPORT"
  time_cmd "first-prefetch-msi" \
    bash "$ROOT/scripts/cyder-prefetch-bootstrap-msi.sh"
  time_cmd "first-ensure-engine" \
    bash "$LAUNCHER" --engine-src "$ENGINE_SRC" --ensure-engine-only
  time_cmd "first-ensure-graphics" \
    bash "$LAUNCHER" --ensure-graphics-only
  time_cmd "first-bootstrap" \
    bash "$LAUNCHER" --engine-src "$ENGINE_SRC" --bootstrap-only
fi

python3 - "$OUT" "$APP" "$ROUNDS" "$RUN_FIRST_PREFIX" <<'PY'
import json, sys
from pathlib import Path
from statistics import mean

out, app, rounds, first = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
records = []
records_path = out / "records.jsonl"
if records_path.exists():
    for line in records_path.read_text().splitlines():
        records.append(json.loads(line))

def group(prefix):
    rows = [r for r in records if r["name"].startswith(prefix)]
    return {
        "samples_ms": [r["elapsed_ms"] for r in rows],
        "mean_ms": round(mean(r["elapsed_ms"] for r in rows), 1) if rows else None,
        "last_status": rows[-1]["status"] if rows else None,
    }

bootstrap_substage = {}
timing_path = out / "first-support" / "Logs" / "bootstrap-timing.jsonl"
if timing_path.exists():
    by_stage = {}
    for line in timing_path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        stage = row.get("stage")
        elapsed = row.get("elapsed_ms")
        if stage is None or elapsed is None:
            continue
        by_stage.setdefault(stage, []).append(elapsed)
    bootstrap_substage = {
        stage: {
            "samples_ms": values,
            "mean_ms": round(mean(values), 1),
        }
        for stage, values in sorted(by_stage.items())
    }

summary = {
    "app": app,
    "rounds": rounds,
    "first_prefix": first,
    "groups": {
        "ensure-engine": group("subsequent-ensure-engine"),
        "ensure-graphics": group("subsequent-ensure-graphics"),
        "health-check": group("subsequent-health-check"),
        "exe-engine-ready": group("exe-engine-ready"),
        "exe-marker-stat": group("exe-marker-stat"),
        "uri-scan-live": group("uri-scan-live"),
        "uri-scan-fixture": group("uri-scan-fixture"),
        "first-prefetch-msi": group("first-prefetch-msi"),
        "first-ensure-engine": group("first-ensure-engine"),
        "first-ensure-graphics": group("first-ensure-graphics"),
        "first-bootstrap": group("first-bootstrap"),
    },
    "bootstrap_substage": bootstrap_substage,
    "records": records,
}
(out / "results.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(summary["groups"], indent=2))
if bootstrap_substage:
    print(json.dumps({"bootstrap_substage": bootstrap_substage}, indent=2))
print(f"wrote {out / 'results.json'}")
PY
