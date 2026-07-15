#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

prefix="$TMP/bottles/shared"
cyder_session_acquire "$prefix" 1 0 normal
same_a="$CYDER_SESSION_FILE"
cyder_session_acquire "$prefix" 1 0 normal
same_b="$CYDER_SESSION_FILE"
[[ "$same_a" != "$same_b" ]]
cyder_session_release "$prefix" "$same_a"
cyder_session_release "$prefix" "$same_b"

cyder_session_acquire "$prefix" 1 0 normal
incompatible="$CYDER_SESSION_FILE"
set +e
cyder_session_acquire "$prefix" 0 1 normal >/dev/null 2>&1
incompatible_status=$?
set -e
if [[ "$incompatible_status" == 0 ]]; then
  echo "incompatible same-bottle session unexpectedly acquired" >&2
  exit 1
fi
[[ "$incompatible_status" == 75 ]]
cyder_session_release "$prefix" "$incompatible"

other="$TMP/bottles/other"
cyder_session_acquire "$other" 0 1 background
other_session="$CYDER_SESSION_FILE"
cyder_session_release "$other" "$other_session"

cyder_session_acquire "$prefix" 1 0 normal
shared_session="$CYDER_SESSION_FILE"
cyder_session_acquire "$other" 0 1 background
other_live_session="$CYDER_SESSION_FILE"
cyder_session_release "$other" "$other_live_session"
cyder_session_release "$prefix" "$shared_session"

stale_dir="$(cyder_session_dir "$prefix")"
mkdir -p "$stale_dir"
cat >"$stale_dir/stale.session" <<'EOF'
pid=99999999
sync=msync=0;esync=0;power=normal
mode=normal
EOF
cyder_session_acquire "$prefix" 0 0 normal
fresh="$CYDER_SESSION_FILE"
[[ ! -e "$stale_dir/stale.session" ]]
cyder_session_release "$prefix" "$fresh"

mkdir -p "$stale_dir/.lock"
printf '%s\n' "$$" >"$stale_dir/.lock/pid"
if CYDER_SESSION_LOCK_ATTEMPTS=2 cyder_session_acquire "$prefix" 0 0 normal >/dev/null 2>&1; then
  echo "contended session lock unexpectedly acquired" >&2
  exit 1
fi
rm -rf "$stale_dir/.lock"

mkdir -p "$stale_dir/.lock"
if ! CYDER_SESSION_LOCK_ATTEMPTS=10 cyder_session_acquire "$prefix" 0 0 normal >/dev/null 2>&1; then
  echo "missing-pid stale lock was not recovered" >&2
  exit 1
fi
[[ ! -d "$stale_dir/.lock" ]]
missing_pid_session="$CYDER_SESSION_FILE"
cyder_session_release "$prefix" "$missing_pid_session"

mkdir -p "$stale_dir/.lock"
printf 'corrupt\n' >"$stale_dir/.lock/pid"
if ! CYDER_SESSION_LOCK_ATTEMPTS=10 cyder_session_acquire "$prefix" 0 0 normal >/dev/null 2>&1; then
  echo "invalid-pid stale lock was not recovered" >&2
  exit 1
fi
invalid_pid_session="$CYDER_SESSION_FILE"
cyder_session_release "$prefix" "$invalid_pid_session"

if CYDER_SESSION_LOCK_ATTEMPTS=invalid cyder_session_acquire "$prefix" 0 0 normal >/dev/null 2>&1; then
  echo "invalid lock attempt count was unexpectedly accepted" >&2
  exit 1
fi

echo "PASS test-cyder-session"
