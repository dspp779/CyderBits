# Cyder Launcher Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship **Cyder.app** as a one-click Windows `.exe` launcher with a single shared `SharedPrefix` (mono + tar + hi-res preinstalled), and rename the existing packager to **CyderBits.app** without changing packager behavior.

**Architecture:** Extract shared Python helpers (`cyder_common.py`), add `cyder_launcher.py` for open-exe flow, add `install-libarchive-tar.sh` for GnuWin bsdtar into `syswow64`, split `create-cyder-app.sh` (launcher) vs `create-cyderbits-app.sh` (packager). Cyder.app `Info.plist` registers `.exe` for open/drop; launcher calls `ensure_shared_engine` → `ensure_shared_prefix` → `wine exe`.

**Tech Stack:** Python 3, bash, osascript, Wine x86_64 (CrossOver source build), GnuWin libarchive 2.4.12 (32-bit PE, LGPL).

**Spec:** [2026-07-05-cyder-cyderbits-split-design.md](../specs/2026-07-05-cyder-cyderbits-split-design.md)

---

## File map (Phase 1)

| File | Responsibility |
|------|----------------|
| `scripts/cyder_common.py` | Paths, `ensure_shared_engine`, locale, `init_bottle`, `apply_mac_hires`, `bootstrap_shared_prefix`, `run_wine_exe` |
| `scripts/cyder_launcher.py` | Cyder.app entry: parse argv / pick file / bootstrap / launch |
| `scripts/cyder_create_game_app.py` | CyderBits packager only; imports from `cyder_common` |
| `scripts/install-libarchive-tar.sh` | Install bsdtar→tar.exe + DLLs into prefix `syswow64` |
| `scripts/create-cyder-app.sh` | Build **Cyder.app** (launcher + engine payload) |
| `scripts/create-cyderbits-app.sh` | Build **CyderBits.app** (packager; current `create-cyder-app.sh` behavior) |
| `tools/libarchive/` | Pre-extracted GnuWin bin+dep + `LICENSE.txt` (not the zip archives) |
| `tests/test-cyder-launcher.sh` | Dry-run / path smoke tests |
| `tests/test-install-libarchive-tar.sh` | Tar install smoke |
| `docs/cyder.md` | User doc for launcher |
| `docs/cyderbits.md` | User doc for packager (split from old cyder.md) |

---

### Task 1: Shared module `cyder_common.py`

**Files:**
- Create: `scripts/cyder_common.py`
- Modify: `scripts/cyder_create_game_app.py` (import shared helpers; remove duplicated defs)

- [ ] **Step 1: Create `cyder_common.py` with paths and constants**

```python
# scripts/cyder_common.py
from __future__ import annotations
import os, subprocess
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/Cyder"
ENGINES = SUPPORT / "Engines"
BOTTLES = SUPPORT / "Bottles"
SHARED_PREFIX = SUPPORT / "SharedPrefix"
ADDONS = SUPPORT / "Addons"
ENGINE_NAME = "wine-x86_64"
BOOTSTRAP_MARKER = SHARED_PREFIX / ".cyder-bootstrap-v1"
LIBARCHIVE_ADDON = ADDONS / "libarchive-2.4.12"
```

Move unchanged from `cyder_create_game_app.py`: `run`, `resolve_wine_locale`, `wine_locale_env`, `ensure_shared_engine`, `init_bottle`, `apply_mac_hires`, `MAC_HIRES_REG_ON`.

Add path resolution for bundled vs dev (same `_HERE` / `OGOM` / `SCRIPTS` / `DEFAULT_ENGINE_SRC` / `ENTITLEMENTS` logic currently at top of `cyder_create_game_app.py`).

- [ ] **Step 2: Add `ensure_shared_prefix(wine_bin: Path) -> Path`**

```python
def ensure_shared_prefix(wine_bin: Path) -> Path:
    prefix = SHARED_PREFIX
    if not (prefix / "system.reg").is_file():
        init_bottle(wine_bin, prefix)
    return prefix
```

- [ ] **Step 3: Add `bootstrap_shared_prefix(wine_bin: Path, *, engine_src: Path) -> None`**

Idempotent; skips if `BOOTSTRAP_MARKER` exists.

```python
def bootstrap_shared_prefix(wine_bin: Path, *, engine_src: Path) -> None:
    prefix = ensure_shared_prefix(wine_bin)
    if BOOTSTRAP_MARKER.is_file():
        return
    # mono
    mono_sh = SCRIPTS / "install-wine-mono.sh"
    if mono_sh.is_file():
        env = os.environ.copy()
        env["WINEPREFIX"] = str(prefix)
        env["WINE_INSTALL"] = str(wine_bin.parent.parent)
        subprocess.check_call(["bash", str(mono_sh)], env=env)
    # tar
    tar_sh = SCRIPTS / "install-libarchive-tar.sh"
    if tar_sh.is_file():
        subprocess.check_call(
            ["bash", str(tar_sh), "--prefix", str(prefix)],
            env={**os.environ, "WINE_INSTALL": str(wine_bin.parent.parent)},
        )
    apply_mac_hires(wine_bin, prefix, enable=True)
    BOOTSTRAP_MARKER.write_text("ok\n", encoding="utf-8")
```

- [ ] **Step 4: Add `run_wine_exe(wine_bin: Path, exe: Path, *, prefix: Path) -> None`**

```python
def run_wine_exe(wine_bin: Path, exe: Path, *, prefix: Path) -> None:
    env = wine_locale_env()
    env["WINEPREFIX"] = str(prefix)
    env["WINESERVER"] = str(wine_bin.parent / "wineserver")
    env["WINEMSYNC"] = "1"
    env["WINEDLLOVERRIDES"] = "mshtml="
    env["PATH"] = f"{wine_bin.parent}:{env.get('PATH', '')}"
    loc = resolve_wine_locale()
    env["LANG"] = loc
    env["LC_ALL"] = loc
    cmd = ["arch", "-x86_64", str(wine_bin), str(exe)]
    subprocess.Popen(
        cmd,
        env=env,
        cwd=str(exe.parent),
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
```

- [ ] **Step 5: Refactor `cyder_create_game_app.py` to import from `cyder_common`**

Replace local copies with:

```python
from cyder_common import (
    SUPPORT, ENGINES, BOTTLES, ENGINE_NAME,
    run, ensure_shared_engine, init_bottle, apply_mac_hires,
    resolve_wine_locale, wine_locale_env, MAC_HIRES_REG_ON,
    DEFAULT_ENGINE_SRC, SCRIPTS, ENTITLEMENTS, OGOM,
)
```

Keep packager-only code (osascript GUI, `create_game_app`, icon extraction, `write_game_launcher`) in this file.

- [ ] **Step 6: Smoke import**

Run: `python3 -c "import sys; sys.path.insert(0,'scripts'); import cyder_common; print(cyder_common.SHARED_PREFIX)"`  
Expected: `.../Application Support/Cyder/SharedPrefix`

- [ ] **Step 7: Commit**

```bash
git add scripts/cyder_common.py scripts/cyder_create_game_app.py
git commit -m "refactor: extract cyder_common for launcher and packager"
```

---

### Task 2: `install-libarchive-tar.sh`

**Files:**
- Create: `scripts/install-libarchive-tar.sh`
- Create: `tools/libarchive/LICENSE.txt`
- Create: `tools/libarchive/bin/bsdtar.exe` (+ dlls; extract from user's GnuWin zips once)
- Modify: `.gitignore` (ignore `libarchive-2.4.12-1-bin/` at repo root if present; track `tools/libarchive/`)

- [ ] **Step 1: Prepare `tools/libarchive/` payload**

Extract from `libarchive-2.4.12-1-bin.zip` + `-dep.zip`:

```text
tools/libarchive/
  LICENSE.txt          # LGPL + GnuWin source URL
  bin/bsdtar.exe
  bin/libarchive2.dll
  dep/bzip2.dll
  dep/zlib1.dll
```

Do **not** commit the zip files at repo root; add to `.gitignore`:

```gitignore
libarchive-2.4.12-1-bin/
libarchive-2.4.12-1-dep/
libarchive-2.4.12-1-*.zip
```

- [ ] **Step 2: Write `install-libarchive-tar.sh`**

```bash
#!/usr/bin/env bash
# Install GnuWin libarchive bsdtar as syswow64/tar.exe (BlueCG large zip).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="${1:-${WINEPREFIX:-}}"
if [[ "${1:-}" == "--prefix" ]]; then PREFIX="$2"; fi
[[ -n "$PREFIX" ]] || { echo "Usage: $0 --prefix PATH" >&2; exit 1; }

SRC="$OGOM/tools/libarchive"
BIN="$SRC/bin"
DEP="$SRC/dep"
TARGET="$PREFIX/drive_c/windows/syswow64"
[[ -d "$PREFIX/drive_c/windows/syswow64" ]] || TARGET="$PREFIX/drive_c/windows/system32"

mkdir -p "$TARGET"
for f in bsdtar.exe libarchive2.dll bzip2.dll zlib1.dll; do
  case "$f" in
    bsdtar.exe|libarchive2.dll) cp -f "$BIN/$f" "$TARGET/" ;;
    *) cp -f "$DEP/$f" "$TARGET/" ;;
  esac
done
cp -f "$TARGET/bsdtar.exe" "$TARGET/tar.exe"
echo "Installed tar.exe (bsdtar) -> $TARGET"
```

- [ ] **Step 3: Write failing test `tests/test-install-libarchive-tar.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/drive_c/windows/syswow64"
bash "$ROOT/scripts/install-libarchive-tar.sh" --prefix "$TMP"
assert test -f "$TMP/drive_c/windows/syswow64/tar.exe"
assert test -f "$TMP/drive_c/windows/syswow64/libarchive2.dll"
echo "PASS test-install-libarchive-tar"
```

- [ ] **Step 4: Run test**

Run: `bash tests/test-install-libarchive-tar.sh`  
Expected: `PASS test-install-libarchive-tar`

- [ ] **Step 5: Commit**

```bash
git add scripts/install-libarchive-tar.sh tools/libarchive/ tests/test-install-libarchive-tar.sh .gitignore
git commit -m "feat: add libarchive tar installer for Wine prefix syswow64"
```

---

### Task 3: `cyder_launcher.py`

**Files:**
- Create: `scripts/cyder_launcher.py`
- Test: `tests/test-cyder-launcher.sh`

- [ ] **Step 1: Implement exe resolution**

```python
#!/usr/bin/env python3
"""Cyder launcher — open Windows EXE with shared prefix."""
from __future__ import annotations
import argparse, sys
from pathlib import Path

from cyder_common import (
    DEFAULT_ENGINE_SRC, ensure_shared_engine, bootstrap_shared_prefix,
    SHARED_PREFIX, run_wine_exe, run,
)

def resolve_exe(argv: list[str]) -> Path | None:
    for a in argv:
        p = Path(a).expanduser()
        if p.suffix.lower() == ".exe" and p.is_file():
            return p.resolve()
    return None

def pick_exe() -> Path:
    # reuse osascript from cyder_create_game_app or duplicate minimal choose_exe
    ...
```

Import `choose_exe` from `cyder_create_game_app` or move `choose_exe` to `cyder_common`.

- [ ] **Step 2: Implement `--dry-run`**

```python
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("exe", nargs="*", help="Windows .exe path(s)")
    parser.add_argument("--engine-src", type=Path, default=DEFAULT_ENGINE_SRC)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    exe = resolve_exe(args.exe) or (None if args.dry_run else pick_exe())
    if exe is None:
        sys.exit("No .exe specified")
    engine = ensure_shared_engine(args.engine_src)
    wine = engine / "bin" / "wine"
    if args.dry_run:
        print(f"WINEPREFIX={SHARED_PREFIX}")
        print(f"wine={wine}")
        print(f"exe={exe}")
        print(f"cwd={exe.parent}")
        return
    bootstrap_shared_prefix(wine, engine_src=args.engine_src)
    run_wine_exe(wine, exe, prefix=SHARED_PREFIX)
```

- [ ] **Step 3: Write `tests/test-cyder-launcher.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/game.exe"
touch "$FAKE"
output="$(PYTHONPATH="$ROOT/scripts" python3 "$ROOT/scripts/cyder_launcher.py" "$FAKE" --dry-run 2>&1)"
assert_contains "$output" "SharedPrefix" "dry-run should use SharedPrefix"
assert_contains "$output" "game.exe" "dry-run should show exe path"
echo "PASS test-cyder-launcher"
```

- [ ] **Step 4: Run test**

Run: `bash tests/test-cyder-launcher.sh`  
Expected: PASS (does not require Wine if `--dry-run` skips bootstrap)

Adjust `ensure_shared_engine` dry-run: if `--dry-run`, launcher should **not** install engine — only print intended paths. Add `--dry-run` guard at start of `ensure_shared_engine` call path in launcher only.

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_launcher.py tests/test-cyder-launcher.sh
git commit -m "feat: add Cyder launcher script with dry-run"
```

---

### Task 4: Split app builders

**Files:**
- Modify: `scripts/create-cyder-app.sh` → launcher app
- Create: `scripts/create-cyderbits-app.sh` → packager app (preserve old behavior)
- Fix: icon `SIZES` heredoc in packager script (current file has corrupted lines)

- [ ] **Step 1: Create `create-cyderbits-app.sh`**

Copy current `create-cyder-app.sh` with these renames:

| Old | New |
|-----|-----|
| `Cyder.app` | `CyderBits.app` |
| `CFBundleIdentifier` `local.cyder.app` | `local.cyderbits.app` |
| `CFBundleName` Cyder | CyderBits |
| `MacOS/Cyder` | `MacOS/CyderBits` |
| Launcher runs `cyder_create_game_app.py --gui` | unchanged |

- [ ] **Step 2: Rewrite `create-cyder-app.sh` for launcher**

Key changes:

```bash
APP="$OUT_DIR/Cyder.app"
# MacOS/Cyder launcher:
cat > "$MACOS/Cyder" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
export CYDER_ENGINE_SRC="$RES/engine-payload"
export CYDER_SCRIPTS="$RES/ogom-scripts"
export OGOM="$RES"
export WINE_INSTALL="$RES/engine-payload"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"
export PYTHONUNBUFFERED=1
exec python3 "$RES/cyder_launcher.py" --engine-src "$RES/engine-payload" "$@"
LAUNCHER
```

Ship in Resources:

```bash
cp "$SCRIPT_DIR/cyder_launcher.py" "$RES/"
cp "$SCRIPT_DIR/cyder_common.py" "$RES/"
cp "$SCRIPT_DIR/install-wine-mono.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-libarchive-tar.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/resolve-wine-locale.sh" "$RES/ogom-scripts/"
rsync -a "$OGOM/tools/libarchive/" "$RES/addons/libarchive/"
```

Set `CYDER_LIBARCHIVE_SRC="$RES/addons/libarchive"` in launcher env; teach `install-libarchive-tar.sh` to honor `CYDER_LIBARCHIVE_SRC` when set.

- [ ] **Step 3: Update `Info.plist` for Cyder.app (exe open + drop)**

Add to Cyder.app `Info.plist`:

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Windows Executable</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>com.microsoft.windows-executable</string>
      <string>public.exe</string>
    </array>
  </dict>
</array>
```

Note: macOS may not ship `com.microsoft.windows-executable`; also register extension `exe` via `CFBundleTypeExtensions` if needed:

```xml
<key>CFBundleTypeExtensions</key>
<array><string>exe</string></array>
```

- [ ] **Step 4: Fix icon SIZES block** (both scripts)

Replace corrupted heredoc with:

```bash
while IFS=' ' read -r px name; do
  sips -z "$px" "$px" "$LOGO_PNG" --out "$ICONSET/$name" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES
```

- [ ] **Step 5: Build both apps**

Run:

```bash
bash scripts/build-wine.sh   # if needed
bash scripts/sign-wine.sh
bash scripts/create-cyder-app.sh
bash scripts/create-cyderbits-app.sh
```

Expected: `dist/Cyder.app` and `dist/CyderBits.app` exist.

- [ ] **Step 6: Commit**

```bash
git add scripts/create-cyder-app.sh scripts/create-cyderbits-app.sh
git commit -m "feat: split Cyder launcher and CyderBits packager app builders"
```

---

### Task 5: Bootstrap integration test (manual + script hook)

**Files:**
- Modify: `scripts/cyder_launcher.py` (optional `--bootstrap-only` for testing)
- Create: `tests/test-cyder-bootstrap.sh`

- [ ] **Step 1: Add `--bootstrap-only` flag**

Prints marker path; runs full bootstrap without launching exe. Used for CI/manual when Wine exists.

- [ ] **Step 2: Document manual verification in test script**

```bash
#!/usr/bin/env bash
# Requires: install/wine-x86_64 built, tools/libarchive present
# Sets WINEPREFIX to temp SharedPrefix under tests/tmp/
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -x "$ROOT/install/wine-x86_64/bin/wine" ]] || { echo "SKIP: no wine"; exit 0; }
...
```

Verify after bootstrap:

```bash
WINEPREFIX="$TMP/SharedPrefix" wine reg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode
test -f "$TMP/SharedPrefix/drive_c/windows/syswow64/tar.exe"
test -d "$TMP/SharedPrefix/drive_c/windows/mono"
```

- [ ] **Step 3: Commit**

```bash
git add tests/test-cyder-bootstrap.sh scripts/cyder_launcher.py
git commit -m "test: add Cyder shared prefix bootstrap smoke test"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/cyder.md` — launcher (open exe, SharedPrefix, file association)
- Create: `docs/cyderbits.md` — packager (move old cyder.md packager sections)
- Modify: `README.md`, `README.zh-TW.md`, `docs/scripts.md`

- [ ] **Step 1: Rewrite `docs/cyder.md`**

Sections:

1. Install: `create-cyder-app.sh` → `open dist/Cyder.app`
2. Open exe: double-click Cyder / drag-drop / right-click Open With
3. SharedPrefix location and bootstrap contents (mono, tar, hi-res)
4. BlueCG note: game files stay in place; shared prefix risks
5. Troubleshooting: tar missing → reinstall Cyder; conflicts → use CyderBits

- [ ] **Step 2: Create `docs/cyderbits.md`**

Move packager GUI/CLI flags from old cyder.md; note `create-cyderbits-app.sh`.

- [ ] **Step 3: Update README quick start**

```bash
bash scripts/create-cyder-app.sh      # Cyder launcher
bash scripts/create-cyderbits-app.sh  # CyderBits packager
```

- [ ] **Step 4: Commit**

```bash
git add docs/cyder.md docs/cyderbits.md README.md README.zh-TW.md docs/scripts.md
git commit -m "docs: split Cyder launcher and CyderBits packager guides"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Cyder shared `SharedPrefix` | Task 1, 3 |
| Bootstrap mono/tar/hi-res | Task 1, 2, 5 |
| Open exe A/B/C | Task 3, 4 (Info.plist + argv + pick_exe) |
| CyderBits rename, behavior unchanged | Task 4 |
| Shared engine | Task 1 `ensure_shared_engine` (existing) |
| libarchive LGPL | Task 2 LICENSE |
| Phase 1 YAGNI (no CoW, no prune UI) | Not in plan |
| `run-bluecg.sh` unchanged | No tasks touch it |

---

## Manual QA (after all tasks)

1. `open dist/Cyder.app` → pick `BlueLauncher.exe` → bootstrap once → launcher starts.
2. Drag `foo.exe` onto Cyder.app → runs without picker.
3. `open dist/CyderBits.app` → create game app → still uses `Bottles/`.
4. Second Cyder open → no re-bootstrap (marker present).
5. `bash scripts/run-bluecg.sh` still works for dev.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-05-cyder-launcher-phase1.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — implement tasks in this session with checkpoints  

Which approach?
