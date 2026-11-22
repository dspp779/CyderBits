#!/usr/bin/env bash
# Start TW MapleStory directly with Wine (no Cyder.app) and print the game
# window to control. See docs/games/maplestory/testing.md.
#
#   MS_ACCOUNT_ID=... MS_OTP=... maplestory-launch.sh --game-dir DIR [options]
#
# MS_ACCOUNT_ID is the ServiceAccountID (T9…) and MS_OTP a fresh one-time
# password, both from the Beanfun OTP app in advanced mode. They are passed to
# the game only, never printed or written to the log. An OTP works once.
#
# Options:
#   --game-dir DIR     folder holding MapleStory.exe (required)
#   --backend NAME     dxvk (default) | dxmt | d3dmetal | wined3d
#   --engine DIR       Wine engine root (default: Cyder's installed engine)
#   --prefix DIR       WINEPREFIX (default: Cyder's shared bottle)
#   --log FILE         Wine output (default: $TMPDIR/maplestory-<time>.log)
#   --io-trace         add the engine's WZ I/O trace (+cyderio, timing)
#   --wait SECONDS     how long to wait for the game window (default 120)
#   --dry-run          print the command with the secrets masked; start nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Cyder"
game_dir="" backend=dxvk engine="${HOME}/.cyder/runtime/Engines/wine-x86_64"
prefix="$SUPPORT/bottles/shared" log="" io_trace=0 wait_s=120 dry_run=0

die() { echo "maplestory-launch: $*" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --game-dir) game_dir="${2:?}"; shift ;;
    --backend) backend="${2:?}"; shift ;;
    --engine) engine="${2:?}"; shift ;;
    --prefix) prefix="${2:?}"; shift ;;
    --log) log="${2:?}"; shift ;;
    --io-trace) io_trace=1 ;;
    --wait) wait_s="${2:?}"; shift ;;
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n "$game_dir" && -f "$game_dir/MapleStory.exe" ]] || die "--game-dir must contain MapleStory.exe"
[[ -x "$engine/bin/wine" ]] || die "no Wine at $engine/bin/wine"
[[ -d "$prefix" ]] || die "no prefix at $prefix"
[[ "$wait_s" =~ ^[0-9]+$ ]] || die "--wait needs seconds"
[[ -n "${MS_ACCOUNT_ID:-}" && -n "${MS_OTP:-}" ]] || die "set MS_ACCOUNT_ID and MS_OTP (Beanfun OTP app, advanced mode)"
[[ "$MS_ACCOUNT_ID" =~ ^T9[0-9A-Za-z]+$ ]] || die "MS_ACCOUNT_ID must be the ServiceAccountID (T9…), not the display name"

declare -a env_args=(
  "WINEPREFIX=$prefix"
  "CYDER_MAPLESTORY_FILE_CACHE=1"     # what Cyder sets for MapleStory.exe
  "CYDER_MAPLESTORY_READAHEAD=1"      # same setting (WZ read optimization)
)
case "$backend" in
  dxvk|dxmt) env_args+=("CYDER_GRAPHICS_BACKEND=$backend" "CX_GRAPHICS_BACKEND=$backend") ;;
  d3dmetal)
    gptk="$SUPPORT/runtime/apple_gptk"
    [[ -f "$gptk/external/libd3dshared.dylib" ]] || die "D3DMetal needs GPTK installed by Cyder at $gptk"
    env_args+=("CYDER_GRAPHICS_BACKEND=d3dmetal" "CX_GRAPHICS_BACKEND=d3dmetal" "CYDER_GPTK_ROOT=$gptk"
               "CX_APPLEGPTK_LIBD3DSHARED_PATH=$gptk/external/libd3dshared.dylib" "DYLD_FRAMEWORK_PATH=$gptk/external") ;;
  wined3d) env_args+=("CYDER_GRAPHICS_BACKEND=wined3d" "CX_GRAPHICS_BACKEND=wined3d") ;;
  *) die "--backend must be dxvk, dxmt, d3dmetal or wined3d" ;;
esac
if [[ "$io_trace" == 0 ]]; then
  env_args+=("WINEDEBUG=-all")
else
  env_args+=("WINEDEBUG=-all,+cyderio" "CYDER_MAPLESTORY_IO_TRACE=1" "CYDER_MAPLESTORY_IO_PROFILE=1"
             "CYDER_MAPLESTORY_IO_PROFILE_TIMING=1")
fi
[[ -n "$log" ]] || log="${TMPDIR:-/tmp}/maplestory-$(date +%Y%m%d-%H%M%S).log"
declare -a game_args=(tw.login.maplestory.beanfun.com 8484 BeanFun)

if [[ "$dry_run" == 1 ]]; then
  printf 'cd %q && env' "$game_dir"; printf ' %q' "${env_args[@]}"
  printf ' /usr/bin/arch -x86_64 %q MapleStory.exe' "$engine/bin/wine"; printf ' %q' "${game_args[@]}"
  printf ' <MS_ACCOUNT_ID> <MS_OTP> > %q\n' "$log"
  exit 0
fi

# One MapleStory per prefix: a second copy fails the anti-cheat and wastes the OTP.
if pgrep -f 'MapleStory\.exe' >/dev/null 2>&1; then die "MapleStory is already running; exit it first"; fi

# Epoch offset of CLOCK_MONOTONIC, to place the I/O trace's t= values on the
# same clock as guarded-key's down_at= and xctrace timestamps.
python3 -I -c 'import time;print("%.6f"%(time.time()-time.clock_gettime(time.CLOCK_MONOTONIC)))' > "$log.mono"
(
  cd "$game_dir"
  account="$MS_ACCOUNT_ID" otp="$MS_OTP"
  unset MS_ACCOUNT_ID MS_OTP
  exec env "${env_args[@]}" nohup /usr/bin/arch -x86_64 "$engine/bin/wine" MapleStory.exe \
    "${game_args[@]}" "$account" "$otp" > "$log" 2>&1 < /dev/null
) &
unset MS_OTP
echo "log=$log"

# Swift scripts take seconds to start; compile the lister once.
# CYDER_WINE_WINDOWS_CMD replaces it (tests).
lister="${CYDER_WINE_WINDOWS_CMD:-${TMPDIR:-/tmp}/cyder-wine-windows-$(id -u)}"
if [[ -z "${CYDER_WINE_WINDOWS_CMD:-}" ]] && [[ ! -x "$lister" || "$SCRIPT_DIR/wine-windows.swift" -nt "$lister" ]]; then
  swiftc -O -o "$lister" "$SCRIPT_DIR/wine-windows.swift" 2>/dev/null || lister=""
fi
list_windows() {
  if [[ -n "$lister" ]]; then "$lister"; else swift "$SCRIPT_DIR/wine-windows.swift"; fi
}

deadline=$(( SECONDS + wait_s ))
while (( SECONDS < deadline )); do
  found="$(list_windows 2>/dev/null | python3 -I -c '
import json, sys
rows = [w for w in json.load(sys.stdin).get("windows", []) if w.get("title") == "MapleStory" and w.get("layer") == 0]
if rows:
    w = max(rows, key=lambda r: r["bounds"].get("Width", 0) * r["bounds"].get("Height", 0))
    b = w["bounds"]
    print("pid=%s window_id=%s title=MapleStory size=%sx%s" % (w["pid"], w["window_id"], b.get("Width"), b.get("Height")))
' 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    grep -m1 -o 'graphics backend=[^ ]*' "$log" 2>/dev/null || echo "graphics backend line not in the log yet; check it before measuring"
    exit 0
  fi
  sleep 2
done
echo "maplestory-launch: no MapleStory window after ${wait_s}s; read $log" >&2
exit 1
