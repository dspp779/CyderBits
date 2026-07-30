#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${CX26_SOURCE_ARCHIVE:-$ROOT/tools/archives/crossover-sources-26.3.0.tar.gz}"
UPSTREAM="$ROOT/patches/wine-11.1-rtlwalkframechain-null-function.patch"
CYDER="$ROOT/patches/cyder-ntdll-frame-walk-page-fault-guard.patch"
OBSOLETE="$ROOT/patches/obsolete/cyder-ntdll-frame-walk-guard.patch"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "SKIP ntdll frame-walk patch round-trip: source archive not found at $ARCHIVE"
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-frame-patches.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

tar -xzf "$ARCHIVE" -C "$TMP_DIR" sources/wine/dlls/ntdll/signal_x86_64.c
SOURCE="$TMP_DIR/sources/wine"
FILE="$SOURCE/dlls/ntdll/signal_x86_64.c"
ORIGINAL_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"

patch --forward --batch -s -p1 -d "$SOURCE" < "$UPSTREAM"
patch --forward --batch -s -p1 -d "$SOURCE" < "$CYDER"

# Once both replacements are present, the old combined patch is intentionally
# neither forward- nor reverse-applicable. The final Cyder patch identifies the
# already-migrated state for build-wine.sh.
if patch --forward --batch --dry-run -s -p1 -d "$SOURCE" < "$OBSOLETE" >/dev/null 2>&1 ||
   patch --reverse --batch --dry-run -s -p1 -d "$SOURCE" < "$OBSOLETE" >/dev/null 2>&1; then
  echo "FAIL obsolete patch unexpectedly applies to the migrated source" >&2
  exit 1
fi
patch --reverse --batch --dry-run -s -p1 -d "$SOURCE" < "$CYDER"

patch --reverse --batch -s -p1 -d "$SOURCE" < "$CYDER"
patch --reverse --batch -s -p1 -d "$SOURCE" < "$UPSTREAM"
RESTORED_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
if [[ "$ORIGINAL_SHA" != "$RESTORED_SHA" ]]; then
  echo "FAIL split patch round-trip did not restore the original source" >&2
  exit 1
fi

# Reproduce a Cyder006 incremental tree and verify its deterministic migration.
patch --forward --batch -s -p1 -d "$SOURCE" < "$OBSOLETE"
patch --reverse --batch -s -p1 -d "$SOURCE" < "$OBSOLETE"
patch --forward --batch -s -p1 -d "$SOURCE" < "$UPSTREAM"
patch --forward --batch -s -p1 -d "$SOURCE" < "$CYDER"

rg -Fq 'if (!func) break;' "$FILE"
rg -q '__EXCEPT_PAGE_FAULT' "$FILE"
echo "PASS ntdll frame-walk patch round-trip and Cyder006 migration"
