# Cyder 0.8.0 Graphics Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Cyder 0.8.0 / 0.8.0-maplestory-oem25 with shared DXVK in both engines, App graphics-backend preferences (default/wined3d/dxvk/d3dmetal), GPTK discovery/install without redistributing Apple GPTK, and notarized App builds.

**Architecture:** Settings (schema 4) resolve global + per-profile backend; non-`default` values set `CYDER_GRAPHICS_BACKEND` for Wine CompatDB runtime to apply (overriding rules). D3DMetal uses `CYDER_GPTK_ROOT` pointing at CrossOver’s `apple_gptk` or a user-installed copy under Application Support. DXVK ships in `engine/lib/dxvk` and is provisioned into bottles as today.

**Tech Stack:** Swift AppKit settings UI, Wine CompatDB C patch, bash DXVK build/install, shell tests, Developer ID + notarytool.

**Spec:** `docs/superpowers/specs/2026-07-28-cyder-graphics-backends-design.md`

## Global Constraints

- Version: App `0.8.0`; OEM `0.8.0-maplestory-oem25`
- Never pack Apple/CrossOver GPTK into engine tarball or notarized zip
- D3DMetal UI requires macOS ≥ 14 and a valid GPTK root
- DXVK selection defaults `DXVK_FRAME_RATE=60`; user may choose unlimited (omit env)
- Final backend `default` → do not set `CYDER_GRAPHICS_BACKEND` (CompatDB wins)
- Final backend ≠ `default` → set `CYDER_GRAPHICS_BACKEND` and force-apply in Wine even if a CompatDB rule already chose a backend
- GPTK install source volumes: `/Volumes/Evaluation environment for Windows games *` with `redist/lib/external/libd3dshared.dylib` + `D3DMetal.framework`
- Install destination: `~/Library/Application Support/Cyder/runtime/apple_gptk/` (respect `CYDER_SUPPORT`)
- No `D3DM_ENABLE_METALFX` in this release; no DXMT user-facing option

## File map

| File | Responsibility |
|---|---|
| `scripts/build-dxvk.sh` | Build once; support installing/copying into multiple engines |
| `scripts/install-dxvk-prefix.sh` | Unchanged contract; used by bootstrap |
| `patches/cyder-compatdb-runtime.patch` (+ rebuilt engines) | `CYDER_GPTK_ROOT`; force `CYDER_GRAPHICS_BACKEND` override |
| `scripts/cyder_settings.swift` | schema 4 fields + resolve helpers + env emission |
| `scripts/cyder_settings_ui.swift` | Graphics tab / controls |
| `scripts/cyder_game_*` / profile UI (as exists) | Per-game override controls |
| `scripts/cyder_gptk.swift` | Discover CrossOver / volumes; install/remove runtime GPTK |
| `scripts/cyder_paths.swift` | `appleGptkRuntime` path helper |
| `scripts/cyder_app_main.swift` | Wire GPTK root + backend env in `wineEnvironment` |
| `tests/test-cyder-settings-swift.sh` / new gptk + graphics tests | Regression |
| `docs/release-signing.zh-TW.md`, release notes | OEM notarize + 0.8.0 notes |
| `scripts/create-cyder-app.sh`, `create-cyder-maplestory-oem-app.sh` | Version bump |

---

### Task 1: Shared DXVK artifact for cx26 + oem25

**Files:**
- Modify: `scripts/build-dxvk.sh`
- Modify: `tests/test-cyder-dxvk.sh` (or add `tests/test-cyder-dxvk-multi-engine.sh`)
- Produce: `install/wine-cx26-x86_64/lib/dxvk/` and `install/wine-maplestory-oem25-source-x86_64/lib/dxvk/` (local build outputs)

**Interfaces:**
- Consumes: existing `build-dxvk.sh --engine PATH`
- Produces: identical `d3d11.dll`/`dxgi.dll` hashes under both engines’ `lib/dxvk/{x86_64,i386}-windows/`

- [ ] **Step 1: Extend `build-dxvk.sh` with optional `--install-engine` repeat or post-copy helper**

Add after the existing install-into-`$ENGINE` block:

```bash
# Optional: copy staged DXVK into additional engines without rebuilding.
# Usage: --also-engine /abs/path (repeatable)
ALSO_ENGINES=()
# in getopts/case:
#   --also-engine) ALSO_ENGINES+=("$2"); shift 2 ;;

install_dxvk_into_engine() {
  local dest_engine="$1"
  [[ "$dest_engine" == /* ]] || { echo "Engine path must be absolute: $dest_engine" >&2; return 1; }
  mkdir -p "$dest_engine/lib/dxvk"
  # copy STAGE layout already used for primary ENGINE
  cp -R "$STAGE/." "$dest_engine/lib/dxvk/"
  # keep LICENSE/dxvk.conf if present at STAGE or SOURCE
}
```

Wire primary engine install through `install_dxvk_into_engine`, then loop `ALSO_ENGINES`.

- [ ] **Step 2: Add test that two engine trees get matching shasums**

```bash
# tests/test-cyder-dxvk-multi-engine.sh (dry-run friendly if engines missing)
STAGE="$ROOT/build/maplestory-oem25/dxvk-stage"
# If stage exists from prior build:
test -f "$E1/lib/dxvk/x86_64-windows/d3d11.dll"
h1=$(shasum -a 256 "$E1/lib/dxvk/x86_64-windows/d3d11.dll" | awk '{print $1}')
h2=$(shasum -a 256 "$E2/lib/dxvk/x86_64-windows/d3d11.dll" | awk '{print $1}')
[[ "$h1" == "$h2" ]]
```

- [ ] **Step 3: Run build for both engines (machine with toolchain)**

```bash
bash scripts/build-dxvk.sh \
  --engine /Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64 \
  --also-engine /Users/jjc/ogom/install/wine-cx26-x86_64
bash tests/test-cyder-dxvk.sh
```

Expected: both `lib/dxvk` trees populated; hashes match.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-dxvk.sh tests/test-cyder-dxvk*.sh
git commit -m "feat(dxvk): install shared DXVK artifact into multiple engines"
```

---

### Task 2: Wine CompatDB — `CYDER_GPTK_ROOT` + forced `CYDER_GRAPHICS_BACKEND`

**Files:**
- Modify: `patches/cyder-compatdb-runtime.patch` (and regenerate into Wine sources used by both engines)
- Modify: `tests/test-cyder-compatdb-wine-runtime.sh` / `tests/fixtures/cyder-compatdb-runtime-variants.py` as needed
- Test: extend wine-runtime tests for env override

**Interfaces:**
- Consumes: `CYDER_GRAPHICS_BACKENDS_ROOT`, existing `apply_graphics_backend()`
- Produces:
  - `CYDER_GPTK_ROOT` — absolute path to a GPTK root containing `external/` + `wine/`
  - If set, d3dmetal uses `$CYDER_GPTK_ROOT` instead of `$BACKENDS_ROOT/lib64/apple_gptk`
  - After CompatDB rule application, if `getenv("CYDER_GRAPHICS_BACKEND")` is `wined3d|dxvk|d3dmetal|dxmt`, call `apply_graphics_backend` again (**force**, even if a rule already applied)

- [ ] **Step 1: Write failing runtime fixture expectation**

In the wine-runtime test harness, add a case:

```text
env CYDER_GRAPHICS_BACKEND=dxvk
# with backends root containing lib/dxvk + MoltenVK
# expect child CX_ACTIVE_GRAPHICS_BACKEND=dxvk
# and WINEDLLOVERRIDES containing d3d11=n,b
```

And:

```text
env CYDER_GPTK_ROOT=/tmp/fake-gptk
env CYDER_GRAPHICS_BACKEND=d3dmetal
# fake-gptk has external/libd3dshared.dylib, D3DMetal.framework stub files, wine/<arch>/d3d11.dll
# expect CX_APPLEGPTK_LIBD3DSHARED_PATH under CYDER_GPTK_ROOT
```

- [ ] **Step 2: Run test — expect FAIL on current Wine**

```bash
bash tests/test-cyder-compatdb-wine-runtime.sh
```

Expected: new cases fail (backend not forced / GPTK root ignored).

- [ ] **Step 3: Patch `apply_graphics_backend` d3dmetal path selection**

Replace hard-coded `$root/lib64/apple_gptk` resolution with:

```c
const char *gptk = getenv( "CYDER_GPTK_ROOT" );
if (gptk && gptk[0])
{
    /* path = gptk/wine, shared = gptk/external/libd3dshared.dylib */
}
else
{
    /* existing: root/lib64/apple_gptk/... */
}
```

- [ ] **Step 4: After CompatDB applies rules, force env backend**

In the process-setup path (same file as rule application), after rules:

```c
const char *forced = getenv( "CYDER_GRAPHICS_BACKEND" );
if (forced && strcmp( forced, "default" ) && strcmp( forced, "" ))
{
    struct cyder_slice slice = { (const unsigned char *)forced, strlen( forced ) };
    if (valid_graphics_backend( &slice ))
        apply_graphics_backend( &slice, applied );
}
```

Ensure this runs even when `applied->graphics_backend` is already TRUE (explicit force).

- [ ] **Step 5: Rebuild/patch engines that ship CompatDB runtime; re-run tests**

```bash
bash tests/test-cyder-compatdb-wine-runtime.sh
bash tests/test-cyder-compatdb-data.sh
```

Expected: PASS including new cases.

- [ ] **Step 6: Commit**

```bash
git add patches/cyder-compatdb-runtime.patch tests/test-cyder-compatdb-wine-runtime.sh tests/fixtures/*
git commit -m "feat(wine): honor CYDER_GPTK_ROOT and forced CYDER_GRAPHICS_BACKEND"
```

---

### Task 3: Settings model (schema 4) + resolve helpers

**Files:**
- Modify: `scripts/cyder_settings.swift`
- Modify: `tests/test-cyder-settings-swift.sh`
- Modify: any golden settings fixtures under `tests/`

**Interfaces:**
- Consumes: existing `CyderSettings` / `CyderExecutableSettings`
- Produces:

```swift
enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`, wined3d, dxvk, d3dmetal
}

enum CyderDxvkFrameRate: String, Codable, CaseIterable {
    case sixty = "60"
    case unlimited
}

// On CyderSettings:
var graphicsBackend: CyderGraphicsBackend // default .default
var dxvkFrameRate: CyderDxvkFrameRate     // default .sixty

// On CyderExecutableSettings:
var graphicsBackend: CyderGraphicsBackend? // nil = follow global
var dxvkFrameRate: CyderDxvkFrameRate?

struct CyderResolvedGraphics {
    var backend: CyderGraphicsBackend
    var dxvkFrameRate: CyderDxvkFrameRate
}

static func resolveGraphics(
    global: CyderSettings,
    profile: CyderExecutableSettings?
) -> CyderResolvedGraphics
```

Env emission in `environment(...)`:

```swift
let g = CyderSettings.resolveGraphics(global: value, profile: rule)
if g.backend != .default {
    result["CYDER_GRAPHICS_BACKEND"] = g.backend.rawValue
}
if g.backend == .dxvk, g.dxvkFrameRate == .sixty {
    result["DXVK_FRAME_RATE"] = "60"
} else {
    // do not set DXVK_FRAME_RATE
}
```

Bump `schemaVersion` to **4**; decoder accepts ≤4; writers always write 4.

- [ ] **Step 1: Extend `test-cyder-settings-swift.sh` with schema 4 cases**

```bash
# decode schema 3 without graphics fields → defaults default/60
# resolve: global dxvk + profile nil → dxvk/60
# resolve: global dxvk + profile unlimited → dxvk/unlimited
# resolve: global wined3d + profile default → default (explicit profile default wins)
# environment(): dxvk+60 sets CYDER_GRAPHICS_BACKEND=dxvk and DXVK_FRAME_RATE=60
# environment(): default sets neither CYDER_GRAPHICS_BACKEND nor DXVK_FRAME_RATE
```

- [ ] **Step 2: Run — expect FAIL**

```bash
bash tests/test-cyder-settings-swift.sh
```

- [ ] **Step 3: Implement model + resolve + env in `cyder_settings.swift`**

Include sanitize: invalid backend strings → `default`; invalid frame rate → `sixty`.

- [ ] **Step 4: Run — expect PASS**

```bash
bash tests/test-cyder-settings-swift.sh
bash tests/test-cyder-golden-settings.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_settings.swift tests/test-cyder-settings-swift.sh tests/test-cyder-golden-settings.sh
git commit -m "feat(settings): add schema 4 graphics backend and DXVK frame rate"
```

---

### Task 4: GPTK discovery + install/remove (`cyder_gptk.swift`)

**Files:**
- Create: `scripts/cyder_gptk.swift`
- Modify: `scripts/cyder_paths.swift` — add `appleGptkRuntime`
- Create: `tests/test-cyder-gptk-swift.sh` (compile+run small driver or `swift` script tests via existing pattern)
- Modify: `scripts/create-cyder-app.sh` / OEM app script to compile new Swift file into the app target list

**Interfaces:**
- Consumes: FileManager, `CyderPaths.support`
- Produces:

```swift
enum CyderGptkSource: Equatable {
    case crossOver(URL)   // .../lib64/apple_gptk
    case runtime(URL)     // Application Support/.../runtime/apple_gptk
}

struct CyderGptkVolumeCandidate: Equatable {
    var volumeRoot: URL
    var displayName: String
    var libRoot: URL      // .../redist/lib
}

enum CyderGptk {
    static let crossOverAppleGptk: URL = /* /Applications/CrossOver.app/.../apple_gptk */

    static func isValidGptkRoot(_ root: URL) -> Bool
    static func preferredSource() -> CyderGptkSource?  // CrossOver first, else runtime
    static func scanEvaluationVolumes() -> [CyderGptkVolumeCandidate]
    static func install(from candidate: CyderGptkVolumeCandidate) throws
    static func removeRuntimeInstall() throws
    static func runtimeManifestURL() -> URL
}
```

Validation: `external/libd3dshared.dylib` exists and is readable; `external/D3DMetal.framework` exists (dir).

Install: copy `candidate.libRoot` contents → `CyderPaths.support/runtime/apple_gptk/` atomically (stage in temp dir, replace). Write JSON manifest `{ "sourceVolume": "...", "displayName": "...", "installedAt": ISO8601 }`.

Volume scan: list `/Volumes`, prefix match `Evaluation environment for Windows games`, require `redist/lib` valid.

- [ ] **Step 1: Failing tests with fake volume tree under TMP**

```bash
mkdir -p "$TMP/Volumes/Evaluation environment for Windows games 3.0/redist/lib/external/D3DMetal.framework"
touch "$TMP/Volumes/Evaluation environment for Windows games 3.0/redist/lib/external/libd3dshared.dylib"
# point scanner at TMP/Volumes via env CYDER_TEST_VOLUMES_ROOT if added for tests
```

- [ ] **Step 2: Implement `cyder_gptk.swift` + path helper**

```swift
// cyder_paths.swift
static var appleGptkRuntime: URL {
    support.appendingPathComponent("runtime/apple_gptk", isDirectory: true)
}
```

- [ ] **Step 3: Run GPTK unit tests — PASS**

- [ ] **Step 4: Wire file into App compile lists in `create-cyder-app.sh` / OEM script**

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_gptk.swift scripts/cyder_paths.swift scripts/create-cyder-app.sh scripts/create-cyder-maplestory-oem-app.sh tests/test-cyder-gptk-swift.sh
git commit -m "feat(gptk): discover CrossOver and install Evaluation DMG into runtime"
```

---

### Task 5: Preferences UI — Graphics tab

**Files:**
- Modify: `scripts/cyder_settings_ui.swift`
- Modify: per-game settings UI file(s) that edit `CyderExecutableSettings` (search `powerMode` / advanced profile editor)
- Test: `tests/test-cyder-force-settings-ui.sh` / snapshot smoke if any; otherwise manual checklist in commit message + lightweight UI presence test if pattern exists

**Interfaces:**
- Consumes: `CyderSettings.graphicsBackend`, `dxvkFrameRate`, `CyderGptk`
- Produces: user-visible controls that call `CyderSettingsStore.update`

- [ ] **Step 1: Add `makeGraphicsTab()` to settings window**

Rows:

1. Popup: 圖形轉譯 — Default / WineD3D / DXVK / D3DMetal  
2. Help text (static NSTextField) per selection  
3. When DXVK selected: popup 限制幀率 — 60 / 不限制  
4. D3DMetal status line: 「可用：CrossOver」／「可用：已安裝評估版」／「不可用：…」  
5. Buttons: 「安裝 Apple GPTK…」「移除已安裝 GPTK」（後者 only if runtime install exists）  
6. macOS &lt; 14: disable D3DMetal menu item; tooltip 需要 macOS 14+

Install button flow:

```swift
let candidates = CyderGptk.scanEvaluationVolumes()
if candidates.isEmpty {
  // alert: 請先開啟 Evaluation environment for Windows games DMG 並同意授權
} else {
  // NSAlert with NSPopUpButton or select from candidates.displayName
  // on OK: CyderGptk.install(from:)
}
```

- [ ] **Step 2: Per-game override**

Same backend + frame-rate controls with an initial 「跟隨全域」 state mapping to `nil` optional fields.

- [ ] **Step 3: Manual smoke + any automated UI compile test**

```bash
# compile app (ad-hoc) or existing swift test target
SIGN_IDENTITY=- bash scripts/create-cyder-app.sh  # only if needed for compile check; prefer unit tests
```

- [ ] **Step 4: Commit**

```bash
git add scripts/cyder_settings_ui.swift scripts/cyder_*game*.swift scripts/cyder_*profile*.swift
git commit -m "feat(ui): add graphics backend preferences and GPTK install controls"
```

---

### Task 6: Launch wiring in `wineEnvironment`

**Files:**
- Modify: `scripts/cyder_app_main.swift` (`wineEnvironment`)
- Modify: `tests/test-cyder-game-launch-settings.sh` (or add graphics cases)

**Interfaces:**
- Consumes: resolved settings env (`CYDER_GRAPHICS_BACKEND`, `DXVK_FRAME_RATE`), `CyderGptk.preferredSource()`
- Produces: process env including `CYDER_GPTK_ROOT`, `CX_APPLEGPTK_LIBD3DSHARED_PATH`, `DYLD_FRAMEWORK_PATH` when backend is d3dmetal or GPTK present

- [ ] **Step 1: Failing launch-env test**

Assert that when settings emit `CYDER_GRAPHICS_BACKEND=d3dmetal`, launcher adds:

```text
CYDER_GPTK_ROOT=<preferred gptk root>
CX_APPLEGPTK_LIBD3DSHARED_PATH=<root>/external/libd3dshared.dylib
DYLD_FRAMEWORK_PATH contains <root>/external
```

And does **not** invent engine `lib64/apple_gptk` if missing.

- [ ] **Step 2: Implement in `wineEnvironment` after settings merge**

```swift
if let source = CyderGptk.preferredSource() {
    let root: URL = {
        switch source {
        case .crossOver(let u), .runtime(let u): return u
        }
    }()
    environment["CYDER_GPTK_ROOT"] = root.path
    let shared = root.appendingPathComponent("external/libd3dshared.dylib")
    if FileManager.default.isReadableFile(atPath: shared.path) {
        environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared.path
    }
    let external = root.appendingPathComponent("external", isDirectory: true).path
    let existing = environment["DYLD_FRAMEWORK_PATH"] ?? ""
    environment["DYLD_FRAMEWORK_PATH"] = existing.isEmpty ? external : external + ":" + existing
}
// Keep CYDER_GRAPHICS_BACKENDS_ROOT = engineRoot for DXVK/MoltenVK layout
```

Log at info: active backend + GPTK source (`crossOver`/`runtime`/`none`).

- [ ] **Step 3: DXVK vs D3DMetal DLL conflict note**

Rely on Wine `apply_graphics_backend`: dxvk → `n,b` + prepend `lib/dxvk`; d3dmetal → `b` + prepend GPTK `wine/`. Add a launch test that documents expected `CX_ACTIVE_GRAPHICS_BACKEND` when forcing each. If prefix native DXVK still wins in practice, add a follow-up step in this task to stash/restore prefix DLLs when switching — only if smoke fails.

- [ ] **Step 4: Run launch settings tests — PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_app_main.swift tests/test-cyder-game-launch-settings.sh
git commit -m "feat(launcher): wire GPTK root and graphics backend into Wine env"
```

---

### Task 7: Docs + version bump to 0.8.0

**Files:**
- Modify: `scripts/create-cyder-app.sh` / OEM script default `CYDER_APP_VERSION`
- Create: `docs/releases/v0.8.0.md` (+ `.en.md` if repo pattern requires)
- Modify: `docs/release-signing.zh-TW.md` — OEM notarize section
- Modify: `docs/README.md` / games docs pointer to graphics prefs
- Short user-facing note in prefs help or `docs/cyder-graphics-backends.zh-TW.md`

Content must state:

- GPTK not redistributed; CrossOver or Evaluation DMG install
- DXVK frame limit vs in-game VSync
- macOS 14+ for D3DMetal

- [ ] **Step 1: Write release notes and signing doc updates**

- [ ] **Step 2: Bump version strings to 0.8.0 / 0.8.0-maplestory-oem25**

- [ ] **Step 3: Commit**

```bash
git add docs/ scripts/create-cyder-app.sh scripts/create-cyder-maplestory-oem-app.sh
git commit -m "docs(release): prepare Cyder 0.8.0 graphics backends notes"
```

---

### Task 8: Package, sign, notarize both Apps

**Files:**
- Use: `scripts/create-cyder-app.sh`, `scripts/create-cyder-maplestory-oem-app.sh`, `docs/release-signing.zh-TW.md`
- Verify engines include `lib/dxvk` and **exclude** `lib64/apple_gptk` from tarball/App payload

- [ ] **Step 1: Pack engines with DXVK, without GPTK**

```bash
# ensure lib/dxvk present; ensure no apple_gptk in packed engine
bash scripts/pack-engine-artifact.sh   # cx26 path as documented
# OEM engine pack path as used for maplestory-oem25
```

- [ ] **Step 2: Build both Apps with Developer ID**

```bash
bash scripts/create-cyder-app.sh
bash scripts/create-cyder-maplestory-oem-app.sh
```

- [ ] **Step 3: Notarize each App (from release-signing doc)**

```bash
ditto -c -k --keepParent dist/Cyder.app dist/Cyder-notarize.zip
xcrun notarytool submit dist/Cyder-notarize.zip --keychain-profile cyder-notary --wait
xcrun stapler staple dist/Cyder.app
# repeat for Cyder-maplestory-oem25.app
```

- [ ] **Step 4: Smoke checklist**

1. Prefs → DXVK + 60 → MapleStory HUD ~60 without game VSync  
2. Prefs → D3DMetal with CrossOver present → `CX_ACTIVE_GRAPHICS_BACKEND` / lsof shows D3DMetal  
3. Quit CrossOver GPTK path; install from mounted Evaluation volume; D3DMetal still works  
4. macOS gate / missing GPTK greys out correctly  
5. `default` does not set `CYDER_GRAPHICS_BACKEND`

- [ ] **Step 5: Final commit of any packaging script fixes + tag if requested**

```bash
git commit -m "chore(release): Cyder 0.8.0 graphics backend packaging fixes"
```

---

## Spec coverage self-check

| Spec item | Task |
|---|---|
| Shared DXVK in cx26 + oem25 | Task 1 |
| No GPTK in engine artifact | Task 1, 8 |
| Settings default/wined3d/dxvk/d3dmetal | Task 3, 5 |
| Global + per-game override | Task 3, 5 |
| default → CompatDB | Task 3, 6 |
| non-default overrides CompatDB | Task 2, 6 |
| DXVK_FRAME_RATE 60 / unlimited | Task 3, 5, 6 |
| macOS ≥ 14 gate | Task 5 |
| CrossOver GPTK direct use | Task 4, 6 |
| Evaluation DMG multi-volume choose + install | Task 4, 5 |
| Remove runtime GPTK | Task 4, 5 |
| Launch env + logging | Task 6 |
| Docs + 0.8.0 | Task 7 |
| Sign + notarize both Apps | Task 8 |
| No MetalFX | Global Constraints |

## Placeholder scan

No TBD/TODO left in task steps; Wine rebuild mechanics deferred to existing `build-wine.sh` / patch apply workflow already used for CompatDB (Task 2 Step 5).
