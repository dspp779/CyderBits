# BlueCG Wine Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Goal:** Build a project-local x86_64 CrossOver Wine runtime that can launch `BlueCrossgateNew` on macOS with ad-hoc signing and no dependency on the system Homebrew at `/opt/homebrew`.
>
> **Architecture:** Shell toolchain under `scripts/` plus smoke tests under `tests/`. `env-x86_64.sh` centralizes paths; `build-wine.sh` bootstraps isolated Homebrew, installs deps, and compiles clean CrossOver Wine sources; `sign-wine.sh` recursively signs Mach-O outputs with `sources/wine/entitlements.plist`; `run-bluecg.sh` / `verify-bluecg.sh` drive the existing `BlueCrossgateNew` prefix using the official launcher `DDRAW.dll` by default. Known macOS workarounds are **documented only** (not automated) and considered only if a clean build fails.
>
> **Tech Stack:** Bash, Rosetta 2, project-local Homebrew (`.brew-x86`), llvm-mingw, CrossOver Wine (`sources/wine`), macOS `codesign`, shell smoke tests.
>
> **Revision:** 2026-07-04 — Task 0 (`git init`), Homebrew bootstrap, respect existing ignore/index config, failure playbook, macOS workarounds as **docs-only** reference. See `docs/superpowers/specs/2026-07-04-bluecg-wine-build-plan-revision-design.md`.

---

## Prerequisites (host)

Before any task, the machine must have:

| Check | Command | Pass condition |
|-------|---------|----------------|
| Rosetta 2 | `arch -x86_64 true` | exit 0 |
| Xcode CLT or Xcode | `xcode-select -p` | prints a path |
| llvm-mingw tree | `test -x llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang` | exit 0 |
| Wine sources | `test -f sources/wine/configure.ac` | exit 0 |
| Entitlements | `test -f sources/wine/entitlements.plist` | exit 0 |
| Game prefix | `test -f BlueCrossgateNew/BlueLauncher.exe` | exit 0 |

If any check fails, stop and fix the host before continuing.

**Prefix risk:** `BlueCrossgateNew/` is an existing commercial CrossOver prefix. Reuse it by default; if G3/G4 fail only with the self-built Wine, suspect leftover registry / DLL overrides and compare against a fresh prefix.

## Already present (do not overwrite carelessly)

These files already exist and encode the indexing / ignore policy:

| File | Role |
|------|------|
| `.cursorignore` | Cursor indexing + agent search excludes (keeps `sources/wine/`) |
| `.vscode/settings.json` | `files.watcherExclude` / `search.exclude` |
| `.gitignore` | Build outputs only (Task 0 expands it for safe `git init`) |

**Indexing note for agents:** Do not run broad `rg` / `Glob` over `BlueCrossgateNew/`, `llvm-mingw-*/`, or non-wine `sources/*`. Prefer exact paths under `docs/`, `scripts/`, `tests/`, and `sources/wine/`.

## Out of scope (v1)

- arm64 native Wine
- Docker PE builds
- DDrawCompat / cnc-ddraw integration
- CrossOver.app packaging
- Apple notarization / Developer ID

## macOS build workarounds (docs only — not scripts)

Prior native-build experience. **Do not automate** these in `scripts/`. Default build uses clean `sources/wine`. If a clean build or run fails, consult this section, decide whether any subset of W1–W3 applies (one, two, or all three), verify each is still appropriate, and prefer a proper fix when one exists.

| ID | Purpose | File | Manual command (from `sources/wine/`) |
|----|---------|------|----------------------------------------|
| W1 | Bypass Vulkan soname | `dlls/win32u/vulkan.c` | `sed -i '' 's/SONAME_LIBVULKAN/"libMoltenVK.dylib"/g' dlls/win32u/vulkan.c` |
| W2 | Stock Metal layer | `dlls/winemac.drv/cocoa_window.m` | `sed -i '' 's/WineMetalLayer/CAMetalLayer/g' dlls/winemac.drv/cocoa_window.m` |
| W3 | Skip 3D present sync | `dlls/winemac.drv/event.c` | `sed -i '' '/macdrv_client_surface_presented/d' dlls/winemac.drv/event.c` |

### When to consider

| ID | Likely failure signal | Prefer first |
|----|----------------------|--------------|
| W1 | configure/link missing Vulkan; `dlopen` Vulkan fails | Install MoltenVK / vulkan-loader via `.brew-x86`; let configure detect it |
| W2 | compile/runtime error in `WineMetalLayer` / CW HACK 22435 | Confirm ddraw path; avoid D3DMetal-only code paths |
| W3 | crash/hang in present / `CLIENT_SURFACE_PRESENTED` | `WINEDEBUG` to find real fault; compare commercial CrossOver |

Record in `logs/workarounds.md` which IDs were applied and why.

### Restore after any source edit

From repo root (adjust tar member paths if `tar -t` shows a different prefix):

```bash
TAR=crossover-sources-26.2.0.tar.gz

# restore only the files you changed, e.g. all three:
tar -xOf "$TAR" sources/wine/dlls/win32u/vulkan.c \
  > sources/wine/dlls/win32u/vulkan.c
tar -xOf "$TAR" sources/wine/dlls/winemac.drv/cocoa_window.m \
  > sources/wine/dlls/winemac.drv/cocoa_window.m
tar -xOf "$TAR" sources/wine/dlls/winemac.drv/event.c \
  > sources/wine/dlls/winemac.drv/event.c

bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

Verify clean markers:

```bash
grep -n 'SONAME_LIBVULKAN' sources/wine/dlls/win32u/vulkan.c
grep -n 'WineMetalLayer' sources/wine/dlls/winemac.drv/cocoa_window.m
grep -n 'macdrv_client_surface_presented' sources/wine/dlls/winemac.drv/event.c
```

## Planned files

| Path | Action | Responsibility |
|------|--------|----------------|
| `.gitignore` | Update (Task 0) | Exclude game, toolchain, sources tree, archives, build outputs |
| `.cursorignore` | Keep | Do not strip wine-preserving rules |
| `.vscode/settings.json` | Keep | Do not strip exclude rules |
| `scripts/env-x86_64.sh` | Create | Paths + Rosetta env |
| `scripts/build-wine.sh` | Create | Bootstrap brew, deps, configure, make, install (clean sources) |
| `scripts/sign-wine.sh` | Create | Recursive ad-hoc codesign |
| `scripts/run-bluecg.sh` | Create | Launch BlueLauncher / bluecg |
| `scripts/verify-bluecg.sh` | Create | G1–G4 checks + failure playbook |
| `tests/assert.sh` | Create | Assertion helpers |
| `tests/test-*.sh` | Create | Dry-run smoke tests |

---

### Task 0: Git Init And Safe Initial Commit

**Files:**
- Update: `.gitignore`
- Keep: `.cursorignore`, `.vscode/settings.json`, `docs/superpowers/**`

- [ ] **Step 1: Expand `.gitignore` so `git add` cannot pull in huge trees**

Replace `.gitignore` with:

```gitignore
# Build toolchain and outputs
.brew-x86/
install/
sources/wine/build64/
tests/tmp/
logs/

# Large local trees (stay on disk; not versioned)
BlueCrossgateNew/
sources/
llvm-mingw-20260616-ucrt-macos-universal/
cnc-ddraw/

# Archives and binary drops
*.tar.gz
*.tar.xz
*.zip
ddraw.dll
mingliu.ttc

# OS / editor noise
.DS_Store
```

- [ ] **Step 2: Initialize git and make the initial commit**

Run:

```bash
cd /Users/jjc/ogom
git init
git add .gitignore .cursorignore .vscode docs
git status
git commit -m "chore: initialize repo with docs and index excludes"
```

Expected `git status` before commit: only the listed config/docs paths staged; **no** `BlueCrossgateNew`, `sources`, or `llvm-mingw` entries.

Expected after commit:

```text
[main (root-commit) ........] chore: initialize repo with docs and index excludes
```

- [ ] **Step 3: Verify prerequisites**

Run:

```bash
arch -x86_64 true
xcode-select -p
test -x llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang
test -f sources/wine/configure.ac
test -f sources/wine/entitlements.plist
test -f BlueCrossgateNew/BlueLauncher.exe
```

Expected: all commands exit 0.

---

### Task 1: Environment Script

**Files:**
- Create: `scripts/env-x86_64.sh`
- Create: `tests/assert.sh`
- Create: `tests/test-env-x86_64.sh`
- Do **not** recreate `.cursorignore` or `.vscode/settings.json`

- [ ] **Step 1: Write the failing test**

Create `tests/assert.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "ASSERT_EQ failed: $message" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ASSERT_CONTAINS failed: $message" >&2
    echo "  missing: $needle" >&2
    exit 1
  fi
}
```

Create `tests/test-env-x86_64.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/env-x86_64.sh"

assert_eq "$OGOM" "$ROOT" "OGOM should point to the repository root"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "Homebrew prefix should stay inside the repo"
assert_eq "$LLVM_MINGW" "$ROOT/llvm-mingw-20260616-ucrt-macos-universal" "llvm-mingw path should match the local toolchain"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-x86_64" "Wine install prefix should stay inside install/"
assert_eq "$WINE_SRC" "$ROOT/sources/wine" "Wine source tree should point at sources/wine"
assert_eq "$BLUECG_PREFIX" "$ROOT/BlueCrossgateNew" "Game prefix should point at BlueCrossgateNew"
assert_eq "$ENTITLEMENTS_PLIST" "$ROOT/sources/wine/entitlements.plist" "entitlements path should match CrossOver wine tree"
assert_contains "$PATH" "$ROOT/.brew-x86/bin" "PATH should include isolated Homebrew"
assert_contains "$PATH" "$ROOT/llvm-mingw-20260616-ucrt-macos-universal/bin" "PATH should include llvm-mingw"

echo "PASS test-env-x86_64"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
chmod +x tests/assert.sh tests/test-env-x86_64.sh
bash tests/test-env-x86_64.sh
```

Expected:

```text
tests/test-env-x86_64.sh: line 6: .../scripts/env-x86_64.sh: No such file or directory
```

- [ ] **Step 3: Write minimal implementation**

Create `scripts/env-x86_64.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
export HOMEBREW_PREFIX="$OGOM/.brew-x86"
export LLVM_MINGW="$OGOM/llvm-mingw-20260616-ucrt-macos-universal"
export WINE_INSTALL="$OGOM/install/wine-x86_64"
export WINE_SRC="$OGOM/sources/wine"
export BLUECG_PREFIX="$OGOM/BlueCrossgateNew"
export ENTITLEMENTS_PLIST="$WINE_SRC/entitlements.plist"
export ARCH_CMD="arch -x86_64"
export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
chmod +x scripts/env-x86_64.sh
bash tests/test-env-x86_64.sh
```

Expected:

```text
PASS test-env-x86_64
```

- [ ] **Step 5: Commit**

```bash
git add scripts/env-x86_64.sh tests/assert.sh tests/test-env-x86_64.sh
git commit -m "chore: add local x86 wine build environment"
```

---

### Task 2: Build Script (Homebrew Bootstrap + Wine Compile)

**Files:**
- Create: `scripts/build-wine.sh`
- Create: `tests/test-build-wine.sh`

Homebrew is installed **into** `$OGOM/.brew-x86` by extracting the official `Homebrew/brew` tarball. This must not touch `/opt/homebrew` or `/usr/local`.

Build always uses **clean** `sources/wine`. Do not wire workarounds into this script; if build fails, consult the docs-only workarounds section above and apply/restore manually only as needed.

- [ ] **Step 1: Write the failing test**

Create `tests/test-build-wine.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/build-wine.sh" --dry-run --bootstrap-brew --install-deps 2>&1 || true)"

assert_contains "$output" "Homebrew/brew" "dry-run should bootstrap Homebrew into .brew-x86"
assert_contains "$output" ".brew-x86/bin/brew install autoconf bison flex pkg-config freetype gettext gnutls" "dry-run should install isolated deps"
assert_contains "$output" "./tools/make_requests" "dry-run should rebuild Wine generated files"
assert_contains "$output" "../configure -C --enable-win64 --with-mingw=llvm-mingw" "dry-run should show expected configure flags"
assert_contains "$output" "make -j" "dry-run should show the compile step"
assert_contains "$output" "make install" "dry-run should show the install step"

echo "PASS test-build-wine"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
chmod +x tests/test-build-wine.sh
bash tests/test-build-wine.sh
```

Expected:

```text
ASSERT_CONTAINS failed: dry-run should bootstrap Homebrew into .brew-x86
```

(or missing `build-wine.sh`)

- [ ] **Step 3: Implement `scripts/build-wine.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

DRY_RUN=0
BOOTSTRAP_BREW=0
INSTALL_DEPS=0
CONFIGURE_ONLY=0
JOBS="$(sysctl -n hw.ncpu)"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --bootstrap-brew) BOOTSTRAP_BREW=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --configure-only) CONFIGURE_ONLY=1 ;;
    --jobs)
      JOBS="$2"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

bootstrap_brew() {
  if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    echo "Homebrew already present at $HOMEBREW_PREFIX"
    return 0
  fi

  run mkdir -p "$HOMEBREW_PREFIX"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ curl -L https://github.com/Homebrew/brew/tarball/master | tar xz --strip-components=1 -C $HOMEBREW_PREFIX"
    return 0
  fi

  curl -L https://github.com/Homebrew/brew/tarball/master \
    | tar xz --strip-components=1 -C "$HOMEBREW_PREFIX"
}

if [[ "$BOOTSTRAP_BREW" -eq 1 ]]; then
  bootstrap_brew
fi

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" && "$DRY_RUN" -eq 0 ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/brew; run with --bootstrap-brew first" >&2
    exit 1
  fi
  run arch -x86_64 "$HOMEBREW_PREFIX/bin/brew" install autoconf bison flex pkg-config freetype gettext gnutls
fi

run mkdir -p "$OGOM/install" "$WINE_SRC/build64"

cd "$WINE_SRC"
run ./tools/make_requests
run ./tools/make_specfiles
run ./tools/make_makefiles
run arch -x86_64 env PATH="$HOMEBREW_PREFIX/bin:$PATH" autoreconf -f

cd "$WINE_SRC/build64"
run arch -x86_64 env \
  PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" \
  BISON="$HOMEBREW_PREFIX/opt/bison/bin/bison" \
  PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig" \
  ../configure -C --enable-win64 --with-mingw=llvm-mingw --prefix="$WINE_INSTALL"

if [[ "$CONFIGURE_ONLY" -eq 0 ]]; then
  run arch -x86_64 env PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" make -j"$JOBS"
  run arch -x86_64 env PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" make install
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
chmod +x scripts/build-wine.sh
bash tests/test-build-wine.sh
```

Expected:

```text
PASS test-build-wine
```

- [ ] **Step 5: Commit**

```bash
git add scripts/build-wine.sh tests/test-build-wine.sh
git commit -m "feat: add crossover wine build script"
```

- [ ] **Step 6: Real build (manual / long-running; not part of smoke tests)**

Run:

```bash
bash scripts/build-wine.sh --bootstrap-brew --install-deps
```

Expected:
- `.brew-x86/bin/brew` exists and is used (not `/opt/homebrew/bin/brew`)
- `sources/wine` remains **unpatched**
- `install/wine-x86_64/bin/wine` exists after install

If configure fails looking for PE compilers, confirm `llvm-mingw-.../bin` is on `PATH` via `scripts/env-x86_64.sh`.

If build or runtime fails for Vulkan/Metal/present reasons, consult the **macOS build workarounds (docs only)** section: apply any subset of W1–W3 manually, record what was used in `logs/workarounds.md`, and restore from the tarball when done.


---

### Task 3: Recursive Ad-Hoc Signing

**Files:**
- Create: `scripts/sign-wine.sh`
- Create: `tests/test-sign-wine.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-sign-wine.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/bin" "$TMP/root/share"
touch "$TMP/root/bin/wine" "$TMP/root/bin/wineserver" "$TMP/root/share/readme.txt"

cat > "$TMP/file-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
case "$path" in
  */wine|*/wineserver) echo "Mach-O 64-bit executable x86_64" ;;
  *) echo "ASCII text" ;;
esac
EOF

cat > "$TMP/codesign-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$CODESIGN_LOG"
EOF

cat > "$TMP/xattr-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "xattr $*" >> "$XATTR_LOG"
EOF

chmod +x "$TMP/file-stub" "$TMP/codesign-stub" "$TMP/xattr-stub"
touch "$TMP/entitlements.plist"

output="$(
  FILE_CMD="$TMP/file-stub" \
  CODESIGN_CMD="$TMP/codesign-stub" \
  XATTR_CMD="$TMP/xattr-stub" \
  CODESIGN_LOG="$TMP/codesign.log" \
  XATTR_LOG="$TMP/xattr.log" \
  bash "$ROOT/scripts/sign-wine.sh" --root "$TMP/root" --entitlements "$TMP/entitlements.plist" --dry-run 2>&1 || true
)"

assert_contains "$output" "bin/wine" "dry-run should include wineloader"
assert_contains "$output" "bin/wineserver" "dry-run should include wineserver"

if [[ "$output" == *"readme.txt"* ]]; then
  echo "non-Mach-O file should not be selected for signing" >&2
  exit 1
fi

echo "PASS test-sign-wine"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
chmod +x tests/test-sign-wine.sh
bash tests/test-sign-wine.sh
```

Expected:

```text
ASSERT_CONTAINS failed: dry-run should include wineloader
```

- [ ] **Step 3: Write minimal implementation**

Create `scripts/sign-wine.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

TARGET_ROOT="$WINE_INSTALL"
ENTITLEMENTS="$ENTITLEMENTS_PLIST"
DRY_RUN=0
FILE_CMD="${FILE_CMD:-file}"
CODESIGN_CMD="${CODESIGN_CMD:-codesign}"
XATTR_CMD="${XATTR_CMD:-xattr}"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      TARGET_ROOT="$2"
      shift
      ;;
    --entitlements)
      ENTITLEMENTS="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ -d "$TARGET_ROOT" ]] || { echo "Missing install root: $TARGET_ROOT" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements file: $ENTITLEMENTS" >&2; exit 1; }

run "$XATTR_CMD" -cr "$TARGET_ROOT"

while IFS= read -r -d '' path; do
  if "$FILE_CMD" -b "$path" | grep -q 'Mach-O'; then
    run "$CODESIGN_CMD" --force --sign - \
      --entitlements "$ENTITLEMENTS" \
      --options runtime \
      "$path"
  fi
done < <(find "$TARGET_ROOT" -type f -print0)

run "$CODESIGN_CMD" --verify --deep --strict --verbose=2 "$TARGET_ROOT/bin/wine"
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
chmod +x scripts/sign-wine.sh
bash tests/test-sign-wine.sh
```

Expected:

```text
PASS test-sign-wine
```

- [ ] **Step 5: Commit**

```bash
git add scripts/sign-wine.sh tests/test-sign-wine.sh
git commit -m "feat: add ad-hoc wine signing script"
```

- [ ] **Step 6: Sign the real install prefix**

Run:

```bash
bash scripts/sign-wine.sh
```

Expected: `codesign --verify` succeeds for `install/wine-x86_64/bin/wine`.

---

### Task 4: BlueCG Launcher Script And DDRAW Selection

**Files:**
- Create: `scripts/run-bluecg.sh`
- Create: `tests/test-run-bluecg.sh`

Default DDRAW source is the official 28KB shim at:

`BlueCrossgateNew/BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll`

Copy it to `BlueCrossgateNew/ddraw.dll` (lowercase; matches existing game-dir naming). Do **not** use DDrawCompat in v1.

- [ ] **Step 1: Write the failing test**

Create `tests/test-run-bluecg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/BlueCrossgateNew/BlueLauncher_temp/BlueCG_updatelogin"
touch "$TMP/BlueCrossgateNew/BlueLauncher.exe"
touch "$TMP/BlueCrossgateNew/bluecg.exe"
printf 'official-ddraw' > "$TMP/BlueCrossgateNew/BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll"

output="$(bash "$ROOT/scripts/run-bluecg.sh" --prefix "$TMP/BlueCrossgateNew" --wine-install "$ROOT/install/wine-x86_64" --dry-run 2>&1 || true)"

assert_contains "$output" "cp" "dry-run should copy the official DDRAW.dll into the game root"
assert_contains "$output" "ddraw.dll" "copy target should be lowercase ddraw.dll"
assert_contains "$output" "BlueLauncher.exe" "launcher mode should start BlueLauncher.exe by default"
assert_contains "$output" "arch -x86_64" "launcher should run under Rosetta x86_64"

echo "PASS test-run-bluecg"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
chmod +x tests/test-run-bluecg.sh
bash tests/test-run-bluecg.sh
```

Expected:

```text
ASSERT_CONTAINS failed: dry-run should copy the official DDRAW.dll into the game root
```

- [ ] **Step 3: Write minimal implementation**

Create `scripts/run-bluecg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="$BLUECG_PREFIX"
DDRAW_SOURCE="official"
MODE="launcher"
DRY_RUN=0
GAME_ARGS=(updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:1 GAHD)

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift
      ;;
    --wine-install)
      WINE_INSTALL="$2"
      shift
      ;;
    --ddraw-source)
      DDRAW_SOURCE="$2"
      shift
      ;;
    --direct) MODE="direct" ;;
    --soft3d)
      GAME_ARGS=(updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:0)
      ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

WINE_BIN="$WINE_INSTALL/bin/wine"
OFFICIAL_DDRAW="$PREFIX/BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll"
LOCAL_DDRAW="$PREFIX/ddraw.dll"

[[ -d "$PREFIX" ]] || { echo "Missing BlueCG prefix: $PREFIX" >&2; exit 1; }
[[ -x "$WINE_BIN" || "$DRY_RUN" -eq 1 ]] || { echo "Missing wine binary: $WINE_BIN" >&2; exit 1; }

case "$DDRAW_SOURCE" in
  official)
    [[ -f "$OFFICIAL_DDRAW" ]] || { echo "Missing official DDRAW.dll: $OFFICIAL_DDRAW" >&2; exit 1; }
    run cp "$OFFICIAL_DDRAW" "$LOCAL_DDRAW"
    ;;
  builtin)
    run rm -f "$LOCAL_DDRAW"
    ;;
  local)
    [[ -f "$LOCAL_DDRAW" ]] || { echo "Missing local ddraw.dll: $LOCAL_DDRAW" >&2; exit 1; }
    ;;
  *)
    echo "Unknown DDRAW source: $DDRAW_SOURCE" >&2
    exit 1
    ;;
esac

export WINEPREFIX="$PREFIX"
export LANG=zh_TW.UTF-8
export PATH="$WINE_INSTALL/bin:$PATH"

cd "$PREFIX"

if [[ "$MODE" == "launcher" ]]; then
  run arch -x86_64 "$WINE_BIN" BlueLauncher.exe
else
  run arch -x86_64 "$WINE_BIN" bluecg.exe "${GAME_ARGS[@]}"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
chmod +x scripts/run-bluecg.sh
bash tests/test-run-bluecg.sh
```

Expected:

```text
PASS test-run-bluecg
```

- [ ] **Step 5: Commit**

```bash
git add scripts/run-bluecg.sh tests/test-run-bluecg.sh
git commit -m "feat: add bluecg launcher wrapper"
```

---

### Task 5: Verification Script (G1–G4) And Failure Playbook

**Files:**
- Create: `scripts/verify-bluecg.sh`
- Create: `tests/test-verify-bluecg.sh`

Gates:

| Gate | Check | Pass |
|------|-------|------|
| G1 | `wine --version` | prints version, not killed |
| G2 | `wine winecfg` | GUI opens |
| G3 | `BlueLauncher.exe` | launcher UI appears |
| G4 | enter game | interactive BlueCG window |

- [ ] **Step 1: Write the failing test**

Create `tests/test-verify-bluecg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/verify-bluecg.sh" --dry-run --with-gui 2>&1 || true)"

assert_contains "$output" "wine --version" "verification should include G1"
assert_contains "$output" "winecfg" "verification should include G2 when --with-gui is set"
assert_contains "$output" "run-bluecg.sh" "verification should delegate launcher startup"
assert_contains "$output" "Manual checks:" "verification should print the G3/G4 checklist"
assert_contains "$output" "AMFI" "verification should mention AMFI failure playbook"
assert_contains "$output" "workarounds" "playbook should mention optional source workarounds"

echo "PASS test-verify-bluecg"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
chmod +x tests/test-verify-bluecg.sh
bash tests/test-verify-bluecg.sh
```

Expected:

```text
ASSERT_CONTAINS failed: verification should include G1
```

- [ ] **Step 3: Write minimal implementation**

Create `scripts/verify-bluecg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

DRY_RUN=0
WITH_GUI=0

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --with-gui) WITH_GUI=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

export PATH="$WINE_INSTALL/bin:$PATH"

echo "G1: wine --version"
run arch -x86_64 "$WINE_INSTALL/bin/wine" --version

if [[ "$WITH_GUI" -eq 1 ]]; then
  echo "G2: wine winecfg"
  run arch -x86_64 "$WINE_INSTALL/bin/wine" winecfg
fi

echo "G3 dry-run: launcher command"
run "$SCRIPT_DIR/run-bluecg.sh" --ddraw-source official --dry-run

cat <<'EOF'
Manual checks:
1. Run: bash scripts/run-bluecg.sh
2. Confirm BlueLauncher.exe UI appears (G3).
3. Start HD1 mode and confirm bluecg.exe becomes visible (G4).
4. Enter the game world; verify MingLiU text and DirectDraw rendering.

Failure playbook (process killed / no output):
1. Re-run: bash scripts/sign-wine.sh
2. Clear quarantine: xattr -cr install/wine-x86_64
3. Inspect AMFI:
   log show --predicate 'eventMessage CONTAINS "AMFI"' --last 2m
4. If Gatekeeper blocks an x86 binary, allow it in System Settings (user action).
5. Collect debug log for game crashes (not kill-on-launch):
   WINEDEBUG=+module,+virtual,+seh arch -x86_64 install/wine-x86_64/bin/wine bluecg.exe \
     updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:0 \
     2>&1 | tee logs/bluecg-debug.log

Optional source workarounds (docs only; only after clean build fails):
1. Match error to W1/W2/W3 in the plan; try preferred fix first.
2. Manually apply any needed subset (one, two, or all three) with the sed commands in the plan.
3. Record applied IDs in logs/workarounds.md, then rebuild + resign.
4. When done or ineffective, restore changed files from crossover-sources-26.2.0.tar.gz and rebuild + resign.
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
chmod +x scripts/verify-bluecg.sh
bash tests/test-verify-bluecg.sh
```

Expected:

```text
PASS test-verify-bluecg
```

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-bluecg.sh tests/test-verify-bluecg.sh
git commit -m "test: add bluecg verification workflow"
```

---

## End-to-end manual sequence

After Tasks 0–5 scripts exist and smoke tests pass:

```bash
# 1. Toolchain + clean Wine sources (long; no workarounds)
bash scripts/build-wine.sh --bootstrap-brew --install-deps

# 2. Sign
bash scripts/sign-wine.sh

# 3. Automated gates (G1; G2 if GUI available)
bash scripts/verify-bluecg.sh --with-gui

# 4. Play
bash scripts/run-bluecg.sh
```

Success criteria match the design spec:

- G1/G2: self-built Wine is not AMFI-killed
- G3/G4: BlueLauncher → BlueCG interactive, comparable to commercial CrossOver

---

## Spec coverage

| Spec requirement | Task |
|------------------|------|
| Isolated `.brew-x86` (no `/opt/homebrew`) | Task 0 ignore, Task 1 env, Task 2 bootstrap |
| CrossOver `sources/wine` build | Task 2 |
| Optional workarounds W1–W3 (any subset) | Docs-only section; not scripts |
| Restore modified sources after experiments | Docs-only: restore from tarball |
| Ad-hoc sign + entitlements | Task 3 |
| `WINEPREFIX=BlueCrossgateNew` + BlueLauncher | Task 4 |
| Official DDRAW (not DDrawCompat) | Task 4 |
| G1–G4 verification | Task 5 |
| Git history for scripts | Task 0 + commits |
| Index excludes preserved | Task 0/1 notes; no overwrite of `.cursorignore` |

## Placeholder scan

- No TBD / TODO placeholders.
- Every code step includes full file contents.
- Every validation step includes exact commands and expected results.
- Commit messages use Conventional Commits.
