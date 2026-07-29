#!/bin/zsh

set -eu

if (( $# != 4 )); then
    print -u2 "用法: $0 <帳號/啟動識別碼> <session token> <參數3> <參數4>"
    exit 64
fi

repo_root="${0:A:h:h}"
wine_runtime="${MAPLE_WINE_RUNTIME:-$repo_root/tools/runtime/wine-cx26-maple-patched}"
wine_prefix="${MAPLE_WINEPREFIX:-$HOME/Library/Application Support/Cyder/bottles/shared}"
game_exe="${MAPLE_GAME_EXE:-$HOME/games/tms_cw/Maplestory_Classic.exe}"

if [[ ! -x "$wine_runtime/bin/wine" ]]; then
    print -u2 "找不到 Wine runtime: $wine_runtime"
    exit 66
fi

if [[ ! -f "$game_exe" ]]; then
    print -u2 "找不到遊戲執行檔: $game_exe"
    exit 66
fi

export WINEPREFIX="$wine_prefix"
export WINEDLLOVERRIDES="d3d11,dxgi=n,b"
export WINEDEBUG="-all"

exec arch -x86_64 "$wine_runtime/bin/wine" "$game_exe" "$@"
