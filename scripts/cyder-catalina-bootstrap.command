#!/bin/bash
# Catalina first-run bootstrap. Terminal is intentionally visible so a failed
# legacy installation never disappears behind a GUI-only stderr stream.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$(cd "$RES/../.." && pwd)"
SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
LOCK_DIR="$SUPPORT/catalina-bootstrap.lock"
PROGRESS_FILE="$SUPPORT/catalina-bootstrap.progress"
WORKER_PID=""

mkdir -p "$SUPPORT" "$SUPPORT/Logs"

release_lock() {
  [[ "$PROGRESS_FILE" == "$SUPPORT/"* ]] && rm -f "$PROGRESS_FILE"
  if [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

stop_worker() {
  if [[ "$WORKER_PID" =~ ^[0-9]+$ ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    kill "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
  fi
  exit 130
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  local existing_pid=""
  if [[ -f "$LOCK_DIR/pid" && ! -L "$LOCK_DIR/pid" ]]; then
    existing_pid="$(tr -d '[:space:]' <"$LOCK_DIR/pid")"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "Cyder 初始化已經在另一個終端機視窗中執行。"
    return 1
  fi

  # Recover only this exact stale lock directory; never recurse through it.
  if [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  mkdir "$LOCK_DIR" || return 1
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

if ! acquire_lock; then
  /usr/bin/osascript -e 'display alert "Cyder 正在初始化" message "請等待目前的安裝作業完成。" as informational' 2>/dev/null || true
  exit 0
fi
trap release_lock EXIT
trap stop_worker HUP INT TERM

ENGINE_ARCHIVE="$(tr -d '[:space:]' <"$RES/engine-archive.txt" 2>/dev/null || true)"
if [[ -n "$ENGINE_ARCHIVE" && -f "$RES/$ENGINE_ARCHIVE" ]]; then
  ENGINE_SRC="$RES/$ENGINE_ARCHIVE"
else
  ENGINE_VER="$(tr -d '[:space:]' <"$RES/engine-version.txt" 2>/dev/null || true)"
  if [[ -n "$ENGINE_VER" && -f "$RES/engine-$ENGINE_VER.tar.zst" ]]; then
    ENGINE_SRC="$RES/engine-$ENGINE_VER.tar.zst"
  elif [[ -n "$ENGINE_VER" && -f "$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz" ]]; then
    ENGINE_SRC="$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz"
  else
    ENGINE_SRC="$RES/engine-payload"
  fi
fi

export CYDER_ENGINE_SRC="$ENGINE_SRC"
export CYDER_SCRIPTS="$SCRIPT_DIR"
export CYDER_LIBARCHIVE_SRC="$RES/addons/libarchive"
export OGOM="$RES"
export WINE_INSTALL="$ENGINE_SRC"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"
export CYDER_ENTITLEMENTS="$RES/entitlements.plist"
export CYDER_APP="$APP"
export CYDER_BUNDLE_ID="local.cyder.app"
export CYDER_PROGRESS_FILE="$PROGRESS_FILE"
export CYDER_GUI=1

rm -f "$PROGRESS_FILE"
clear 2>/dev/null || true
echo "Cyder 首次安裝"
echo "=============="
echo
echo "正在建立 Windows 遊戲執行環境，請勿關閉此視窗。"
echo "所需時間會依電腦與儲存裝置速度而異。"
echo
printf '[%s] %s\n' "$(date '+%H:%M:%S')" "正在安裝 Wine engine…"

bash "$SCRIPT_DIR/cyder_launcher.sh" \
  --engine-src "$ENGINE_SRC" \
  --bootstrap-only &
WORKER_PID=$!

last_progress=""
while kill -0 "$WORKER_PID" 2>/dev/null; do
  if [[ -f "$PROGRESS_FILE" && ! -L "$PROGRESS_FILE" ]]; then
    progress="$(tail -n 1 "$PROGRESS_FILE" 2>/dev/null || true)"
    if [[ -n "$progress" && "$progress" != "$last_progress" ]]; then
      printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$progress"
      last_progress="$progress"
    fi
  fi
  sleep 1
done

set +e
wait "$WORKER_PID"
status=$?
set -e
WORKER_PID=""

if [[ "$status" -eq 0 ]]; then
  echo
  echo "Cyder 初始化完成。"
  /usr/bin/osascript -e 'display alert "Cyder 初始化完成" message "Windows 遊戲執行環境已準備完成。" as informational' 2>/dev/null || true
  /usr/bin/open "$APP" >/dev/null 2>&1 || true
  exit 0
fi

echo
echo "Cyder 初始化失敗（exit $status）。"
echo "診斷記錄：$SUPPORT/Logs/bootstrap-error.log"
/usr/bin/osascript -e 'display alert "Cyder 初始化失敗" message "請保留終端機內容，並查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log。" as warning' 2>/dev/null || true
echo
read -r -p "按 Enter 關閉此視窗… " _ || true
exit "$status"
