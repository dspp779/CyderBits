# Game-library EXE icons via winemenubuilder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cyder.app 遊戲庫磁貼改以暫存 `.lnk` + `winemenubuilder -t` 抽 PNG，執行期不再呼叫 `/usr/bin/python3`。

**Architecture:** 新增 bundled `cyder-extract-exe-icon.sh` 為唯一 Wine 呼叫點。Swift `CyderGameIconStore` 把已開啟的 EXE `FileHandle` 拷到 `icon-extract/<id>/game.exe`，再跑該腳本；cache 仍是 `game-icons/<id>.png`。不改 engine、不 `wineserver -k`。

**Tech Stack:** bash 3.2、`arch -x86_64` Wine 11 / CX26、AppKit `Process`、`tests/assert.sh`。

## Global Constraints

- 規格：`docs/superpowers/specs/2026-08-19-exe-icon-winemenubuilder-design.md`
- `winemenubuilder -t` 只對 **Unix 路徑的 `.lnk`**；禁止把 `.exe` 丟給 `-t`。
- `.lnk` 的 `TargetPath` 必須是 `winepath -w` 轉出的 DOS 路徑（scratch 在 Application Support，不在 `drive_c`）。
- 超時 45 秒；只殺 cscript／winemenubuilder 子行程，禁止 `wineserver -k`。
- 失敗：中性 SF Symbol，禁止 `NSWorkspace.shared.icon(forFile:)`。
- 不改 `cyder-wine-engine`；不 cherry-pick Wine MR 6489／6555。
- CyderBits／`cyder_create_game_app.py` 的 `--extract-icon` 可留；本版只改遊戲庫。
- Commit 用 Conventional Commits；**僅在使用者要求時 `git commit`**（使用者規則優先於計畫裡的 Commit 步驟：那時略過 commit，繼續下一任務）。

## File map

| 檔案 | 責任 |
|------|------|
| `scripts/cyder-extract-exe-icon.sh` | 建 `.lnk`、呼叫 `winemenubuilder -t`、清 scratch |
| `tests/test-cyder-extract-exe-icon.sh` | 契約 + 可選 Wine 整合（皮卡丘 EXE） |
| `scripts/cyder_game_icon.swift` | 停用 python3；拷 FD；跑 helper；45s |
| `scripts/cyder_paths.swift` | `iconExtractRoot` |
| `scripts/create-cyder-app.sh` | 打包 helper |
| `tests/test-cyder-app-payload.sh` | 改打包契約 |
| `tests/test-cyder-bottle-shortcuts.sh` | 禁止 icon store 用 python3 |
| `tests/test-exe-to-icns.sh` | `--extract-icon-stdin` 改標為 CyderBits，不是遊戲庫 |

不改：`cyder-wine-engine`、`winemac.drv`、CyderBits launcher。

---

### Task 1: Shell helper 與契約／整合測試

**Files:**
- Create: `tests/test-cyder-extract-exe-icon.sh`
- Create: `scripts/cyder-extract-exe-icon.sh`
- Test: `tests/test-cyder-extract-exe-icon.sh`

**Interfaces:**
- Consumes: `WINEPREFIX`、可執行的 `wine`（env `CYDER_WINE` 或 argv `--wine`）
- Produces: `cyder-extract-exe-icon.sh --exe <unix.exe> --png <unix.png> [--wine <path>] [--scratch <dir>]`；成功時 PNG 非空且 magic 為 PNG；結束時刪除 scratch 內 `game.exe`／`game.lnk`／`make_lnk.js`

- [ ] **Step 1: Write the failing test**

建立 `tests/test-cyder-extract-exe-icon.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

HELPER="$ROOT/scripts/cyder-extract-exe-icon.sh"
assert test -f "$HELPER"
assert test -x "$HELPER"
helper_src="$(cat "$HELPER")"
assert_not_contains "$helper_src" "python3" \
  "icon helper must not invoke python3 (CLT stub)"
assert_not_contains "$helper_src" "wineserver -k" \
  "icon helper must not kill wineserver"
assert_contains "$helper_src" "winemenubuilder.exe" \
  "icon helper must use winemenubuilder"
assert_contains "$helper_src" "winepath" \
  "lnk TargetPath must be converted with winepath -w"
assert_contains "$helper_src" "cscript" \
  "lnk must be created with cscript / WScript.Shell"

# Direct .exe to -t is upstream-unsupported; helper must pass the .lnk.
assert_contains "$helper_src" 'winemenubuilder.exe -t "$lnk"' \
  "winemenubuilder -t must receive the unix .lnk path"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-extract-icon-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
set +e
missing_out="$("$HELPER" --exe "$tmp/missing.exe" --png "$tmp/out.png" 2>&1)"
missing_status=$?
set -e
assert_eq "$missing_status" "1" "missing WINEPREFIX and exe must fail closed"
assert_contains "$missing_out" "WINEPREFIX" "failure must mention WINEPREFIX or missing inputs"

PIKA="$ROOT/dist/皮卡丘打排球.exe"
WINE="${CYDER_WINE:-$HOME/.cyder/runtime/Engines/wine-x86_64/bin/wine}"
PREFIX="${WINEPREFIX:-$HOME/Library/Application Support/Cyder/bottles/shared}"
if [[ -f "$PIKA" && -x "$WINE" && -f "$PREFIX/.cyder-bootstrap-v1" ]]; then
  scratch="$tmp/scratch"
  mkdir -p "$scratch"
  cp "$PIKA" "$scratch/game.exe"
  png="$tmp/from-lnk.png"
  WINEPREFIX="$PREFIX" \
    "$HELPER" --wine "$WINE" --exe "$scratch/game.exe" --png "$png" --scratch "$scratch"
  assert test -s "$png"
  magic="$(dd if="$png" bs=8 count=1 2>/dev/null | xxd -p)"
  assert_contains "$magic" "89504e47" "output must be a PNG"
  assert test ! -e "$scratch/game.exe"
  assert test ! -e "$scratch/game.lnk"

  set +e
  WINEPREFIX="$PREFIX" WINESERVER="${WINE%/wine}/wineserver" \
    arch -x86_64 "$WINE" winemenubuilder.exe -t "$scratch/../nope.exe" "$tmp/direct.png" >/dev/null 2>&1
  # Recreate a copy only to prove -t on exe still fails:
  cp "$PIKA" "$tmp/direct.exe"
  WINEDEBUG="-all" WINEPREFIX="$PREFIX" WINESERVER="${WINE%/wine}/wineserver" \
    arch -x86_64 "$WINE" winemenubuilder.exe -t "$tmp/direct.exe" "$tmp/direct.png" >"$tmp/direct.log" 2>&1
  set -e
  assert test ! -s "$tmp/direct.png"
  assert_contains "$(cat "$tmp/direct.log")" "could not read .lnk" \
    "winemenubuilder -t on an exe must still fail"
else
  echo "SKIP wine integration (need dist/皮卡丘打排球.exe, wine, and bootstrapped prefix)" >&2
fi

echo "PASS test-cyder-extract-exe-icon"
```

`chmod +x tests/test-cyder-extract-exe-icon.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-extract-exe-icon.sh`

Expected: FAIL，`assert test -f` 找不到 helper，或 helper 尚未可執行。

- [ ] **Step 3: Write minimal implementation**

建立 `scripts/cyder-extract-exe-icon.sh`（bash 3.2；`chmod +x`）：

```bash
#!/usr/bin/env bash
# Extract a PNG from a Windows EXE via a temp .lnk and winemenubuilder -t.
# Does not parse PE. Does not kill wineserver.
set -euo pipefail

usage() {
  echo "Usage: cyder-extract-exe-icon.sh --exe UNIX.exe --png UNIX.png [--wine UNIX/wine] [--scratch DIR]" >&2
  exit 1
}

EXE=""
PNG=""
WINE_BIN="${CYDER_WINE:-}"
SCRATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe) EXE="${2:-}"; shift 2 ;;
    --png) PNG="${2:-}"; shift 2 ;;
    --wine) WINE_BIN="${2:-}"; shift 2 ;;
    --scratch) SCRATCH="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$EXE" && -n "$PNG" && -f "$EXE" ]] || {
  echo "Missing --exe/--png or exe file" >&2
  exit 1
}
[[ -n "${WINEPREFIX:-}" && -d "$WINEPREFIX" ]] || {
  echo "WINEPREFIX is required" >&2
  exit 1
}

if [[ -z "$WINE_BIN" ]]; then
  WINE_BIN="${CYDER_ENGINES:-$HOME/.cyder/runtime/Engines}/${CYDER_ENGINE_NAME:-wine-x86_64}/bin/wine"
fi
[[ -x "$WINE_BIN" ]] || {
  echo "Missing wine: $WINE_BIN" >&2
  exit 1
}

WINESERVER="${WINESERVER:-${WINE_BIN%/wine}/wineserver}"
export WINEPREFIX WINESERVER
export WINEDEBUG="${WINEDEBUG:--all}"

if [[ -z "$SCRATCH" ]]; then
  SCRATCH="$(cd "$(dirname "$EXE")" && pwd)/.cyder-icon-work.$$"
  mkdir -p "$SCRATCH"
  cp "$EXE" "$SCRATCH/game.exe"
  OWN_SCRATCH=1
else
  mkdir -p "$SCRATCH"
  if [[ "$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")" != "$(cd "$SCRATCH" && pwd)/game.exe" ]]; then
    cp "$EXE" "$SCRATCH/game.exe"
  fi
  OWN_SCRATCH=0
fi

cleanup() {
  rm -f "$SCRATCH/game.exe" "$SCRATCH/game.lnk" "$SCRATCH/make_lnk.js"
  if [[ "${OWN_SCRATCH:-0}" == 1 ]]; then
    rmdir "$SCRATCH" 2>/dev/null || rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

run_wine() {
  arch -x86_64 "$WINE_BIN" "$@"
}

GAME_UNIX="$(cd "$SCRATCH" && pwd)/game.exe"
DOS_EXE="$(run_wine winepath -w "$GAME_UNIX")"
# JS string: escape backslashes and quotes
JS_TARGET="${DOS_EXE//\\/\\\\}"
JS_TARGET="${JS_TARGET//\"/\\\"}"
JS_LNK="$(run_wine winepath -w "$SCRATCH/game.lnk")"
JS_LNK="${JS_LNK//\\/\\\\}"
JS_LNK="${JS_LNK//\"/\\\"}"

cat >"$SCRATCH/make_lnk.js" <<EOF
var ws = WScript.CreateObject("WScript.Shell");
var sc = ws.CreateShortcut("$JS_LNK");
sc.TargetPath = "$JS_TARGET";
sc.Save();
EOF

run_wine cscript.exe //Nologo "$SCRATCH/make_lnk.js"
lnk="$SCRATCH/game.lnk"
[[ -f "$lnk" ]] || {
  echo "cscript did not create game.lnk" >&2
  exit 1
}

mkdir -p "$(dirname "$PNG")"
run_wine winemenubuilder.exe -t "$lnk" "$PNG"
[[ -s "$PNG" ]] || {
  echo "winemenubuilder produced no PNG" >&2
  exit 1
}
```

注意：`lnk="$SCRATCH/game.lnk"` 必須與測試字串 `winemenubuilder.exe -t "$lnk"` 完全一致。

若 `winepath -w` 對尚未存在的 `game.lnk` 失敗，改成只對 `game.exe` 做 `winepath -w`，JS 裡 `CreateShortcut` 用 **Unix 路徑字串**寫 `.lnk` 檔案位置（實驗證明 `-t` 要 Unix `.lnk`；`CreateShortcut` 的第一個參數可用 Wine 看得到的 DOS 或 Unix——若 DOS 的 lnk 路徑較穩，先 `touch "$SCRATCH/game.lnk"` 再 `winepath -w`）。實作時以整合測試為準：優先 `touch` 空 lnk 再 `winepath -w`。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash tests/test-cyder-extract-exe-icon.sh`

Expected: `PASS test-cyder-extract-exe-icon`（無皮卡丘／無 wine 時仍 PASS，並印 SKIP）。本機有 `dist/皮卡丘打排球.exe` 與 shared prefix 時必須產出 PNG。

- [ ] **Step 5: Commit**（僅當使用者要求）

```bash
git add scripts/cyder-extract-exe-icon.sh tests/test-cyder-extract-exe-icon.sh
git commit -m "$(cat <<'EOF'
feat(app): extract game icons via winemenubuilder lnk

Avoid the macOS python3 CLT stub; use Wine LoadResource like CrossOver menus.
EOF
)"
```

---

### Task 2: 打包進 Cyder.app 並改 Swift 呼叫端

**Files:**
- Modify: `scripts/cyder_paths.swift`（在 `sharedBottle` 附近加 `iconExtractRoot`）
- Modify: `scripts/cyder_game_icon.swift`（整份 `extract`／helper 解析）
- Modify: `scripts/create-cyder-app.sh`（約 230–246 行打包區）
- Modify: `tests/test-cyder-app-payload.sh`（約 56–57 行）
- Modify: `tests/test-cyder-bottle-shortcuts.sh`
- Test: `tests/test-cyder-app-payload.sh`、`tests/test-cyder-bottle-shortcuts.sh`

**Interfaces:**
- Consumes: Task 1 的 `cyder-extract-exe-icon.sh --exe --png --wine --scratch`
- Produces: `CyderGameIconStore` 以 `FileHandle` 寫入 `CyderPaths.iconExtractRoot/<id>/game.exe` 後呼叫 helper；不再引用 `/usr/bin/python3` 或 `cyder_create_game_app.py`

- [ ] **Step 1: Write the failing test**

在 `tests/test-cyder-app-payload.sh` 把：

```bash
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder_create_game_app.py" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the PE icon extraction helper"
```

改成：

```bash
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-extract-exe-icon.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the winemenubuilder icon helper"
assert_contains "$build_script" 'chmod +x "$RES/ogom-scripts/cyder-extract-exe-icon.sh"' \
  "icon helper must be executable in the app bundle"
```

在 `tests/test-cyder-bottle-shortcuts.sh` 的 `PASS` 之前追加：

```bash
assert_not_contains "$icon" "/usr/bin/python3" \
  "game library icon extraction must not invoke the CLT python3 stub"
assert_contains "$icon" "cyder-extract-exe-icon.sh" \
  "game library must call the bundled winemenubuilder helper"
assert_contains "$icon" "45" \
  "icon extraction timeout must be 45 seconds for cold wineserver"
```

（`45` 請對應實際寫成 `timeout: .now() + 45` 或 `45.0`，assert 字串必須與實作相同。）

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-cyder-app-payload.sh`

Expected: FAIL，找不到 `cyder-extract-exe-icon.sh` 的 `cp`。

Run: `bash tests/test-cyder-bottle-shortcuts.sh`

Expected: FAIL，`cyder_game_icon.swift` 仍有 `/usr/bin/python3`。

- [ ] **Step 3: Write minimal implementation**

在 `scripts/cyder_paths.swift` 的 `sharedBottle` 之後加入：

```swift
    static let iconExtractRoot: URL = support
        .appendingPathComponent("icon-extract", isDirectory: true)
```

改 `scripts/cyder_game_icon.swift` 檔首註解為「bundled winemenubuilder helper」，不要提 Python。

`ensureExtracted` 裡 helper 改為：

```swift
        let helper = resources.appendingPathComponent("ogom-scripts/cyder-extract-exe-icon.sh")
```

`extract(...)` 改為（保留 `queue.async`、cache 目錄、`pending`／`failed`／completion 結構）：

```swift
            let scratch = CyderPaths.iconExtractRoot
                .appendingPathComponent(game.id, isDirectory: true)
            let stagedExe = scratch.appendingPathComponent("game.exe")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            do {
                if FileManager.default.fileExists(atPath: stagedExe.path) {
                    try FileManager.default.removeItem(at: stagedExe)
                }
                FileManager.default.createFile(atPath: stagedExe.path, contents: nil)
                let dest = try FileHandle(forWritingTo: stagedExe)
                defer { try? dest.close() }
                while true {
                    let chunk = executable.readData(ofLength: 1024 * 1024)
                    if chunk.isEmpty { break }
                    dest.write(chunk)
                }
            } catch {
                try? executable.close()
                try? FileManager.default.removeItem(at: scratch)
                DispatchQueue.main.async {
                    self.pending.remove(game.id)
                    self.failed.insert(game.id)
                    CyderDiagnostics.shared.warning("game-icon stage-failed id=\(game.id)")
                    completion()
                }
                return
            }
            try? executable.close()

            let wine = CyderPaths.engine.appendingPathComponent("bin/wine")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                helper.path,
                "--exe", stagedExe.path,
                "--png", cacheURL.path,
                "--wine", wine.path,
                "--scratch", scratch.path,
            ]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "WINEPREFIX": CyderPaths.sharedBottle.path,
                "WINESERVER": CyderPaths.engine.appendingPathComponent("bin/wineserver").path,
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
```

bootstrap 守衛：在 `process.run()` 之前，若 `!FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path)` 或 wine 不存在，刪 scratch、`completion()`、**不要** `failed.insert`（之後 bootstrap 完可重試）。

超時：

```swift
                if finished.wait(timeout: .now() + 45) == .success {
                    status = process.terminationStatus
                } else {
                    process.terminate()
                    status = -2
                }
```

`extract` 結束時（成功或失敗）`try? FileManager.default.removeItem(at: scratch)`。成功條件維持 `status == 0` 且 `NSImage(contentsOf: cacheURL) != nil`。

在 `scripts/create-cyder-app.sh` 於 `cp "$SCRIPT_DIR/cyder_create_game_app.py"` **旁邊**加入（可保留 py 給尚未遷移的東西，但遊戲庫不再需要；本任務**仍可暫時 copy py** 以免其他未知引用。規格允許 CyderBits 留 py；Cyder.app 若測試已改為只要求 extract script，就 **改 copy extract script**，py 的 `cp` 可留可刪。本任務刪除遊戲庫對 py 的執行期依賴即可。若 payload 測試不再要求 py，把 py 的 `cp` 留著也沒關係。）

最小變更：在 `cyder-profile.sh` copy 之後加入：

```bash
cp "$SCRIPT_DIR/cyder-extract-exe-icon.sh" "$RES/ogom-scripts/"
chmod +x "$RES/ogom-scripts/cyder-extract-exe-icon.sh"
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run:

```bash
bash tests/test-cyder-extract-exe-icon.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-bottle-shortcuts.sh
```

Expected: 三個都 `PASS`。

- [ ] **Step 5: Commit**（僅當使用者要求）

```bash
git add scripts/cyder-extract-exe-icon.sh scripts/cyder_game_icon.swift scripts/cyder_paths.swift \
  scripts/create-cyder-app.sh tests/test-cyder-app-payload.sh tests/test-cyder-bottle-shortcuts.sh
git commit -m "$(cat <<'EOF'
feat(app): run game-library icon extraction through Wine

Stage the EXE from the granted file handle and drop the python3 helper.
EOF
)"
```

---

### Task 3: 收斂舊的「遊戲庫 = Python stdin」測試文案

**Files:**
- Modify: `tests/test-exe-to-icns.sh`（約 12–14 行）
- Test: `tests/test-exe-to-icns.sh`

**Interfaces:**
- Consumes: 仍存在的 `cyder_create_game_app.py --extract-icon-stdin`（CyderBits）
- Produces: 測試文案不再宣稱遊戲庫走 Python

- [ ] **Step 1: Write the failing test (adjust assertions)**

把：

```bash
assert_contains "$content" '"--extract-icon-stdin"' "game library icon extraction should accept an inherited file descriptor"
```

改成：

```bash
assert_contains "$content" '"--extract-icon-stdin"' "CyderBits packager may still extract PE icons from stdin"
```

- [ ] **Step 2: Run test**

Run: `bash tests/test-exe-to-icns.sh`

Expected: `PASS test-exe-to-icns`（此步只改訊息，通常直接綠）。

- [ ] **Step 3: 無需產品碼**

若 Step 2 已 PASS，本任務沒有實作步驟。

- [ ] **Step 4: Commit**（僅當使用者要求）

```bash
git add tests/test-exe-to-icns.sh
git commit -m "$(cat <<'EOF'
test: stop treating PE stdin extract as the game-library path

EOF
)"
```

---

## Self-review

| Spec | Task |
|------|------|
| 不呼叫 python3 | 1、2 |
| `.lnk` + Unix `-t` | 1 |
| `winepath -w` TargetPath | 1 |
| scratch 在 Application Support，抽完刪 | 1、2 |
| 45s、不 `wineserver -k` | 1、2 |
| 占位圖、禁止 NSWorkspace | 既有 bottle-shortcuts 斷言保留 |
| 皮卡丘整合、無檔 SKIP | 1 |
| 直接 `-t` EXE 仍失敗 | 1 |
| 打包 helper | 2 |
| `--extract-icon-stdin` 改標 CyderBits | 3 |
| 不改 engine／Dock／CyderBits GUI | 無對應改動 |

無 TBD。Helper CLI `--exe/--png/--wine/--scratch` 在 Task 1 定義，Task 2 使用同一組旗標。
