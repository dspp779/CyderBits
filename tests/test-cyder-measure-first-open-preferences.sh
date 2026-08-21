#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/cyder-measure-first-open-preferences.sh"

bash "$SCRIPT" --help | grep -q first-open

# Missing app should fail without touching live support.
if CYDER_APP="$ROOT/dist/Cyder.app.missing" bash "$SCRIPT"; then
  echo "expected failure for missing app" >&2
  exit 1
fi

echo OK
