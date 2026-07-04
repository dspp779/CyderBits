#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
echo $$ > logs/build-wine.pid
rm -f logs/build-wine.exit

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a logs/build-wine.log; }

log "Waiting for any existing brew install in .brew-x86 to finish..."
while pgrep -f '/\.brew-x86/.*brew\.rb install' >/dev/null 2>&1; do
  log "brew install still running (pids: $(pgrep -f '/\.brew-x86/.*brew\.rb install' | tr '\n' ' '))"
  sleep 30
done
log "No brew install lock holders; starting build-wine.sh"

set +e
stdbuf -oL -eL bash scripts/build-wine.sh --bootstrap-brew --install-deps \
  >> logs/build-wine.log 2>&1
ec=$?
echo "$ec" > logs/build-wine.exit
log "build-wine finished exit=$ec"
exit "$ec"
