#!/usr/bin/env bash
# Verify an immutable cyder-wine-engine release before pinning it in Cyder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST=""
APPLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --manifest /path/to/archive.manifest.json [--apply]

Without --apply, verifies the archive, embedded manifest, version, and NTDLL
SHA-256 without changing Cyder. With --apply, copies the archive/manifest into
dist/artifacts/engine-releases and updates config/cyder-engine-*.txt/json.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || { echo "Missing value for --manifest" >&2; exit 1; }
      MANIFEST="$2"
      shift 2
      ;;
    --apply) APPLY=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 1; }
plutil -convert json -o /dev/null -- "$MANIFEST"

field() {
  plutil -extract "$1" raw -o - "$MANIFEST"
}

schema="$(field schemaVersion)"
version="$(field versionLabel)"
artifact_name="$(field artifact)"
expected_archive_sha="$(field artifactSHA256)"
expected_ntdll_sha="$(field ntdllSHA256)"

[[ "$schema" == 1 ]] || { echo "Unsupported engine manifest schema: $schema" >&2; exit 1; }
[[ -n "$version" && "$version" != *$'\n'* ]] || { echo "Invalid engine version" >&2; exit 1; }
[[ "$artifact_name" == "$(basename "$artifact_name")" ]] || {
  echo "Manifest artifact must be a basename" >&2
  exit 1
}
[[ "$expected_archive_sha" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid artifact SHA-256 in manifest" >&2
  exit 1
}
[[ "$expected_ntdll_sha" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid NTDLL SHA-256 in manifest" >&2
  exit 1
}

manifest_dir="$(cd "$(dirname "$MANIFEST")" && pwd -P)"
archive="$manifest_dir/$artifact_name"
[[ -f "$archive" ]] || { echo "Missing engine archive: $archive" >&2; exit 1; }
actual_archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
  echo "Engine archive SHA-256 mismatch" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-engine-import.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

extract_member() {
  local member="$1"
  case "$archive" in
    *.tar.xz) tar -xJOf "$archive" "$member" ;;
    *.tar.zst)
      local zstd_bin
      zstd_bin="${CYDER_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
      [[ -x "$zstd_bin" ]] || {
        echo "zstd is required to verify $archive" >&2
        return 1
      }
      "$zstd_bin" -dc "$archive" | tar -xOf - "$member"
      ;;
    *) echo "Unsupported engine archive format: $archive" >&2; return 1 ;;
  esac
}

archive_version="$(extract_member wine-x86_64/version | head -1)"
[[ "$archive_version" == "$version" ]] || {
  echo "Engine version mismatch: manifest=$version archive=$archive_version" >&2
  exit 1
}
extract_member wine-x86_64/engine-manifest.json >"$TMP_DIR/embedded.json"
plutil -convert json -o /dev/null -- "$TMP_DIR/embedded.json"
embedded_version="$(plutil -extract versionLabel raw -o - "$TMP_DIR/embedded.json")"
embedded_ntdll_sha="$(plutil -extract ntdllSHA256 raw -o - "$TMP_DIR/embedded.json")"
[[ "$embedded_version" == "$version" && "$embedded_ntdll_sha" == "$expected_ntdll_sha" ]] || {
  echo "Embedded engine manifest does not match the release sidecar" >&2
  exit 1
}
extract_member wine-x86_64/lib/wine/x86_64-windows/ntdll.dll >"$TMP_DIR/ntdll.dll"
actual_ntdll_sha="$(shasum -a 256 "$TMP_DIR/ntdll.dll" | awk '{print $1}')"
[[ "$actual_ntdll_sha" == "$expected_ntdll_sha" ]] || {
  echo "Packaged NTDLL SHA-256 mismatch" >&2
  exit 1
}

echo "Verified engine release: $version"
echo "  archive: $artifact_name"
echo "  archive SHA-256: $actual_archive_sha"
echo "  NTDLL SHA-256: $actual_ntdll_sha"

if [[ "$APPLY" -ne 1 ]]; then
  echo "Verification only; pass --apply to update Cyder's pinned engine."
  exit 0
fi

destination_dir="$ROOT/dist/artifacts/engine-releases"
mkdir -p "$destination_dir"
archive_destination="$destination_dir/$artifact_name"
manifest_destination="$destination_dir/$(basename "$MANIFEST")"
cp "$archive" "$archive_destination.tmp"
cp "$MANIFEST" "$manifest_destination.tmp"
mv -f "$archive_destination.tmp" "$archive_destination"
mv -f "$manifest_destination.tmp" "$manifest_destination"

relative_archive="${archive_destination#"$ROOT/"}"
printf '%s\n' "$version" >"$ROOT/config/cyder-engine-version.txt.tmp"
printf '%s\n' "$relative_archive" >"$ROOT/config/cyder-engine-archive.txt.tmp"
cp "$MANIFEST" "$ROOT/config/cyder-engine-manifest.json.tmp"
mv -f "$ROOT/config/cyder-engine-version.txt.tmp" "$ROOT/config/cyder-engine-version.txt"
mv -f "$ROOT/config/cyder-engine-archive.txt.tmp" "$ROOT/config/cyder-engine-archive.txt"
mv -f "$ROOT/config/cyder-engine-manifest.json.tmp" "$ROOT/config/cyder-engine-manifest.json"

echo "Pinned $version for the next Cyder.app build."
