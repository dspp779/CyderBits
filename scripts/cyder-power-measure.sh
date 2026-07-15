#!/usr/bin/env bash
# Interactive, repeatable Wine power/QoS measurement helper for macOS.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  cyder-power-measure.sh --log-name NAME [options]

Start the game manually and enter the chosen scene before running this script.
The script then records taskinfo for wine/wineserver and filtered powermetrics
samples without launching or closing the game.

Options:
  --log-name NAME       Required safe name for this measurement run.
  --output-dir PATH     Parent directory for logs (default: dist/power-benchmarks).
  --duration SECONDS    Formal measurement duration (default: 300).
  --interval SECONDS    taskinfo/powermetrics sample interval (default: 10).
  --warmup SECONDS      Stabilization delay before measurement (default: 10).
  -h, --help            Show this help.
EOF
}

log_name=""
output_dir="$PWD/dist/power-benchmarks"
duration=300
interval=10
warmup=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-name) log_name="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --duration) duration="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --warmup) warmup="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$log_name" ]] || { echo "--log-name is required" >&2; exit 2; }
[[ "$log_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "--log-name may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 2
}
[[ "$duration" =~ ^[1-9][0-9]*$ && "$interval" =~ ^[1-9][0-9]*$ && "$warmup" =~ ^[0-9]+$ ]] || {
  echo "duration/interval must be positive integers; warmup must be zero or positive" >&2
  exit 2
}
[[ $# -eq 0 ]] || { echo "this script does not accept a command; start the game manually first" >&2; usage >&2; exit 2; }

SECONDS=0
run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_dir="$output_dir/${log_name}-${run_stamp}"
mkdir -p "$run_dir"

elapsed_name() {
  printf '%06ds' "$SECONDS"
}

event_log="$run_dir/events-000000s.log"
sudo_status="$run_dir/sudo-status-000000s.log"
keepalive_pid=""
powermetrics_pid=""
powermetrics_raw=""
powermetrics_filtered=""

event() {
  printf '%06ds %s\n' "$SECONDS" "$1" | tee -a "$event_log"
}

stop_powermetrics() {
  [[ -n "$powermetrics_pid" ]] || return 0
  sudo -n kill "$powermetrics_pid" 2>/dev/null || true
  wait "$powermetrics_pid" 2>/dev/null || true
  powermetrics_pid=""
  if [[ -n "$powermetrics_raw" && -f "$powermetrics_raw" ]]; then
    grep -i -E 'wine|wineserver' "$powermetrics_raw" >"$powermetrics_filtered" || true
    rm -f "$powermetrics_raw"
  fi
}

cleanup() {
  stop_powermetrics
  if [[ -n "$keepalive_pid" ]]; then
    kill "$keepalive_pid" 2>/dev/null || true
    wait "$keepalive_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

check_sudo() {
  if [[ -s "$sudo_status" ]]; then
    cat "$sudo_status" >&2
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "sudo credential is unavailable; stopping measurement." >&2
    exit 1
  fi
}

snapshot_taskinfo() {
  local stamp file
  stamp="$(elapsed_name)"
  file="$run_dir/taskinfo-${stamp}.log"
  {
    printf 'elapsed=%s\n' "$stamp"
    printf '\n===== taskinfo wine =====\n'
    sudo -n taskinfo wine 2>&1 || true
    printf '\n===== taskinfo wineserver =====\n'
    sudo -n taskinfo wineserver 2>&1 || true
  } >"$file"
}

prompt_checkpoint() {
  local message="$1"
  read -r -p "$message" _ || true
  event "$message"
}

metadata="$run_dir/metadata-000000s.log"
{
  printf 'run_name=%s\n' "$log_name"
  printf 'started_utc=%s\n' "$run_stamp"
  printf 'duration_seconds=%s\ninterval_seconds=%s\nwarmup_seconds=%s\n' "$duration" "$interval" "$warmup"
  sw_vers 2>/dev/null || true
  system_profiler SPHardwareDataType 2>/dev/null || true
} >"$metadata"

echo "This measurement requires sudo once for taskinfo and powermetrics."
sudo -v
(
  while sleep 60; do
    if ! sudo -n -v 2>/dev/null; then
      printf 'sudo credential refresh failed at %06ds\n' "$SECONDS" >"$sudo_status"
      exit 1
    fi
  done
) &
keepalive_pid=$!

event "measurement script started; game must already be in the chosen scene"
check_sudo
snapshot_taskinfo

if [[ "$warmup" -gt 0 ]]; then
  event "warmup started"
  sleep "$warmup"
  event "warmup completed"
fi

check_sudo
measurement_start="$(elapsed_name)"
powermetrics_raw="$run_dir/.powermetrics-${measurement_start}.raw.log"
powermetrics_filtered="$run_dir/powermetrics-wine-${measurement_start}.log"
samples=$(((duration + interval - 1) / interval))
sudo -n powermetrics \
  --show-process-qos \
  --show-process-qos-tiers \
  --show-process-energy \
  --samplers tasks \
  -i "$((interval * 1000))" \
  -n "$samples" >"$powermetrics_raw" 2>&1 &
powermetrics_pid=$!
event "formal measurement started (duration=${duration}s, interval=${interval}s)"

end_time=$((SECONDS + duration))
while (( SECONDS < end_time )); do
  check_sudo
  snapshot_taskinfo
  sleep "$interval"
done
snapshot_taskinfo
stop_powermetrics
event "formal measurement completed"

prompt_checkpoint "Measurement finished. Close the game and press Enter after all Wine processes exit: "
event "user confirmed game closed"

echo "Logs written to: $run_dir"
