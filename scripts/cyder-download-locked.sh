#!/usr/bin/env bash
# Shared locked download helper for pinned MSI (and similar) artifacts.
# Source from install-wine-mono.sh / install-wine-gecko.sh — do not execute.

cyder_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

# cyder_download_locked DEST URL EXPECTED_SHA256
# Acquires DEST.lock (mkdir), downloads to DEST.part, verifies, moves into place.
cyder_download_locked() {
  local dest="$1" url="$2" expected="$3"
  local lock="${dest}.lock"
  local part="${dest}.part"
  local timeout_sec="${CYDER_DOWNLOAD_LOCK_TIMEOUT_SEC:-300}"
  local start_s now_s
  start_s="$(date +%s)"

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]] && [[ "$(cyder_sha256_file "$dest")" == "$expected" ]]; then
    return 0
  fi

  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -f "$dest" ]] && [[ "$(cyder_sha256_file "$dest")" == "$expected" ]]; then
      return 0
    fi
    now_s="$(date +%s)"
    if (( now_s - start_s >= timeout_sec )); then
      echo "Timed out waiting for download lock: $lock" >&2
      return 1
    fi
    sleep 0.2
  done

  cyder_download_lock_held="$lock"
  # shellcheck disable=SC2154,SC2064
  trap '[[ -n "${cyder_download_lock_held:-}" ]] && rmdir "$cyder_download_lock_held" 2>/dev/null || true; cyder_download_lock_held=' RETURN

  if [[ -f "$dest" ]] && [[ "$(cyder_sha256_file "$dest")" == "$expected" ]]; then
    return 0
  fi

  rm -f "$dest" "$part"
  echo "Downloading $url" >&2
  if ! curl -fL --progress-bar -o "$part" "$url"; then
    rm -f "$part"
    echo "Download failed: $url" >&2
    return 1
  fi
  mv -f "$part" "$dest"
  if [[ "$(cyder_sha256_file "$dest")" != "$expected" ]]; then
    echo "Checksum verification failed: $dest" >&2
    rm -f "$dest"
    return 1
  fi
  return 0
}
