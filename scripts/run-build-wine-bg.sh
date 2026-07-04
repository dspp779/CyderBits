#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
echo $$ > logs/build-wine.pid
set +e
stdbuf -oL -eL bash scripts/build-wine.sh --bootstrap-brew --install-deps \
  > logs/build-wine.log 2>&1
ec=$?
echo "$ec" > logs/build-wine.exit
echo "build-wine finished exit=$ec" >> logs/build-wine.log
exit "$ec"
