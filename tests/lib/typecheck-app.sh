#!/bin/bash
# Typecheck every Swift source the app is built from (create-cyder-app.sh's
# SWIFT_SOURCES), without linking. tests/run.sh --changed runs this when a
# Swift file changed; CYDER_TEST_TYPECHECK_CMD replaces it in runner tests.
set -euo pipefail
if [[ -n "${CYDER_TEST_TYPECHECK_CMD:-}" ]]; then exec bash -c "$CYDER_TEST_TYPECHECK_CMD"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
srcs=()
while IFS= read -r name; do srcs+=("$ROOT/scripts/$name"); done < <(
  sed -n '/^SWIFT_SOURCES=(/,/^)/p' "$ROOT/scripts/create-cyder-app.sh" | grep -o 'cyder_[a-z_]*\.swift')
[[ ${#srcs[@]} -gt 0 ]] || { echo "no Swift sources found in create-cyder-app.sh" >&2; exit 1; }
exec /usr/bin/swiftc -typecheck -module-cache-path "${CYDER_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/cyder-typecheck-cache}" "${srcs[@]}"
