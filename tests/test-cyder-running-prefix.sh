#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d "$ROOT/.rpfx.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

make_prefix() {
  local prefix="$1"
  mkdir -p "$prefix/drive_c/windows/system32"
  : >"$prefix/system.reg"
  : >"$prefix/user.reg"
  : >"$prefix/drive_c/windows/system32/kernel32.dll"
}

socket_path_for_prefix() {
  local prefix="$1" root="$2"
  local device inode
  device="$(stat -f '%d' "$prefix")"
  inode="$(stat -f '%i' "$prefix")"
  printf -v device '%x' "$device"
  printf -v inode '%x' "$inode"
  printf '%s/.wine-%s/server-%s-%s/socket\n' "${root%/}" "$(id -u)" "$device" "$inode"
}

bind_unix_socket() {
  python3 - "$1" <<'PY'
import os, socket, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    os.remove(path)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
PY
}

PREFIX="$TMP/p"
make_prefix "$PREFIX"
if cyder_has_running_prefix "$PREFIX"; then
  echo "ASSERT failed: idle prefix must not look in-use" >&2
  exit 1
fi

SESSION_DIR="$(cyder_session_dir "$PREFIX")"
mkdir -p "$SESSION_DIR"
cat >"$SESSION_DIR/live.session" <<EOF
schema=2
pid=$$
sync=msync=0;esync=0;power=normal
mode=normal
state=running
started_at=1
EOF
cyder_has_running_prefix "$PREFIX" || {
  echo "ASSERT failed: live Cyder session pid must count as in-use" >&2
  exit 1
}
rm -f "$SESSION_DIR/live.session"

TMPDIR_ROOT="$TMP/t"
socket="$(socket_path_for_prefix "$PREFIX" "$TMPDIR_ROOT")"
bind_unix_socket "$socket"
export TMPDIR="$TMPDIR_ROOT"
cyder_has_running_prefix "$PREFIX" || {
  echo "ASSERT failed: wineserver socket under TMPDIR must count as in-use" >&2
  exit 1
}

mkdir -p "$TMP/runtime/Engines/wine-x86_64/bin"
cat >"$TMP/runtime/Engines/wine-x86_64/bin/wine" <<'SH'
#!/usr/bin/env bash
printf 'wine-invoked:%s\n' "$*" >>"${CYDER_TEST_WINE_LOG:-/dev/null}"
exit 0
SH
cat >"$TMP/runtime/Engines/wine-x86_64/bin/wineserver" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/runtime/Engines/wine-x86_64/bin/wine" "$TMP/runtime/Engines/wine-x86_64/bin/wineserver"
printf 'wine crossover 26.3.0 (wine 11.0)\n' >"$TMP/runtime/Engines/wine-x86_64/version"

export CYDER_RUNTIME_ROOT="$TMP/runtime"
export CYDER_SUPPORT="$TMP"
export CYDER_SHARED_PREFIX="$PREFIX"
: >"$PREFIX/.cyder-bootstrap-v1"
mkdir -p "$TMP/Logs/operations"
export CYDER_TEST_WINE_LOG="$TMP/wine.log"
: >"$CYDER_TEST_WINE_LOG"
set +e
health_out="$(
  PATH="$TMP/runtime/Engines/wine-x86_64/bin:/usr/bin:/bin" \
    bash "$ROOT/scripts/cyder_launcher.sh" --health-check 2>&1
)"
health_status=$?
set -e
assert_eq "$health_status" "0" "in-use health-check should succeed without probing"
assert_contains "$health_out" "health probe skipped" "in-use prefix must skip wine cmd"
if [[ -s "$CYDER_TEST_WINE_LOG" ]]; then
  echo "ASSERT failed: health-check must not spawn wine while prefix is in use" >&2
  echo "  $(cat "$CYDER_TEST_WINE_LOG")" >&2
  exit 1
fi

echo "PASS test-cyder-running-prefix"
