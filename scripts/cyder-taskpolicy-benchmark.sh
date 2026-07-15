#!/usr/bin/env bash
# Run the same command under Cyder's three power policies.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: cyder-taskpolicy-benchmark.sh [--duration SECONDS] -- COMMAND [ARGS...]

Runs COMMAND once for normal, utility and background. Collect CPU/Energy
Impact/GPU metrics separately with Activity Monitor or powermetrics.
EOF
}

duration=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
command=("$@")
taskpolicy_bin="$(command -v taskpolicy 2>/dev/null || true)"

for mode in normal utility background; do
  printf '\n=== mode=%s duration=%ss ===\n' "$mode" "$duration"
  if [[ "$duration" =~ ^[1-9][0-9]*$ ]]; then
    if [[ "$mode" == normal ]]; then
      "${command[@]}" & child=$!
    elif [[ -n "$taskpolicy_bin" ]]; then
      if [[ "$mode" == background ]]; then
        "$taskpolicy_bin" -c background "${command[@]}" & child=$!
      else
        "$taskpolicy_bin" -c utility "${command[@]}" & child=$!
      fi
    else
      echo "taskpolicy is unavailable; cannot measure mode=$mode" >&2
      exit 127
    fi
    sleep "$duration"
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  elif [[ "$mode" == normal ]]; then
    "${command[@]}"
  elif [[ -n "$taskpolicy_bin" ]]; then
    if [[ "$mode" == background ]]; then
      "$taskpolicy_bin" -c background "${command[@]}"
    else
      "$taskpolicy_bin" -c utility "${command[@]}"
    fi
  else
    echo "taskpolicy is unavailable; cannot measure mode=$mode" >&2
    exit 127
  fi
done
