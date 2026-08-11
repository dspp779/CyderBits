# Cyder DXVK 2 Graphics Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship DXVK 2.7.1 as a separate Cyder graphics payload and expose a **DXVK 2** menu option that prepends `lib/dxvk2` without replacing 1.10.3.

**Architecture:** Independent CompatDB token `dxvk2` → `ENGINE/lib/dxvk2` (ensure symlink to `current-dxvk2`). Pack `dxvk2-2.7.1.tar.zst` beside existing dxvk/dxmt archives. Settings schema 9 adds `CyderGraphicsBackend.dxvk2`. Existing `dxvk` / CompatDB rules stay on 1.10.3.

**Tech Stack:** Wine ntdll CompatDB patches, bash pack/ensure, Swift settings + AppKit menus, existing shell/Swift harness tests.

## Global Constraints

- `lib/dxvk` remains 1.10.3; `lib/dxvk2` is 2.7.1. Never point `current-dxvk` at 2.x.
- Menu: **DXVK** = 1.10.3, **DXVK 2** = 2.7.1.
- Builtin + prepend only; bottle `d3d*` hashes must not change.
- Engine tarball excludes `lib/dxvk`, `lib/dxmt`, **and** `lib/dxvk2`. MoltenVK stays in the engine.
- `CYDER_GRAPHICS_BACKEND=dxvk2` is ignored until `valid_graphics_backend` accepts it — next shipped Cyder must pin a rebuilt engine.
- Wine rebuild / engine pack lives in `/Users/jjc/cyder-wine-engine`. ogom keeps matching `patches/cyder-compatdb-runtime.patch`.
- Conventional Commits; do not push unless asked.

## File map

| File | Responsibility |
|------|----------------|
| `patches/cyder-compatdb-runtime.patch` + OEM25 + engine copy | Accept `dxvk2`; MoltenVK check for both DXVK families |
| `scripts/pack-graphics-payloads.sh` | Pack + stamp `lib/dxvk2` |
| `scripts/pack-engine-artifact.sh` (+ engine repo copy) | Exclude `lib/dxvk2`; pack graphics first |
| `scripts/create-cyder-app.sh` | Require dxvk2 sidecars in `Resources/graphics/` |
| `scripts/cyder-ensure-graphics.sh` | Install `current-dxvk2` + `lib/dxvk2` symlink |
| `scripts/cyder-common.sh` | `cyder_apply_graphics_preference dxvk2` |
| `scripts/cyder_settings.swift` | Schema 9, `dxvk2`, capabilities, env |
| `scripts/cyder_settings_ui.swift` / `cyder_game_library_ui.swift` | Menu + limiter/HUD |
| `scripts/cyder_app_main.swift` | Treat dxvk2 payload as present |
| `docs/cyder-graphics-backends.zh-TW.md` / `docs/build-dxvk.zh-TW.md` | User + build notes |

---

### Task 1: CompatDB accepts `dxvk2`

**Files:**
- Modify: `patches/cyder-compatdb-runtime.patch`
- Modify: `patches/cyder-compatdb-runtime-oem25.patch` (same C snippets; line numbers differ)
- Modify: `/Users/jjc/cyder-wine-engine/patches/cyder-compatdb-runtime.patch`
- Test: `tests/test-cyder-graphics-prepend-patch.sh`, `tests/test-cyder-compatdb-wine-runtime.sh`

**Interfaces:**
- Consumes: `valid_graphics_backend()`, `apply_graphics_backend()`
- Produces: `dxvk2` is a valid forced backend; MoltenVK required like `dxvk`; prepend path is `root/lib/dxvk2`

- [ ] **Step 1: Extend the prepend-patch test**

Replace `tests/test-cyder-graphics-prepend-patch.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"

for patch in \
  "$ROOT/patches/cyder-compatdb-runtime.patch" \
  "$ROOT/patches/cyder-compatdb-runtime-oem25.patch"
do
  if grep -n 'dxvk.*n,b\|!strcmp( backend, "dxvk" ) ? "n,b"' "$patch"; then
    echo "FAIL: dxvk still uses n,b native-first override in $patch" >&2
    exit 1
  fi
  grep -q 'prepend_dll_path' "$patch"
  assert_contains "$(cat "$patch")" 'slice->size == 5 && !memcmp( slice->data, "dxvk2", 5 )' \
    "$patch must accept graphics_backend dxvk2"
  assert_contains "$(cat "$patch")" '!strcmp( backend, "dxvk2" )' \
    "$patch must treat dxvk2 like dxvk for MoltenVK"
done

echo "PASS test-cyder-graphics-prepend-patch"
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash tests/test-cyder-graphics-prepend-patch.sh`  
Expected: FAIL on missing `dxvk2` memcmp.

- [ ] **Step 3: Patch `valid_graphics_backend` in all three patch files**

In each file, find:

```c
           (slice->size == 4 && !memcmp( slice->data, "dxvk", 4 )) ||
           (slice->size == 4 && !memcmp( slice->data, "dxmt", 4 )) ||
```

Replace with:

```c
           (slice->size == 4 && !memcmp( slice->data, "dxvk", 4 )) ||
           (slice->size == 5 && !memcmp( slice->data, "dxvk2", 5 )) ||
           (slice->size == 4 && !memcmp( slice->data, "dxmt", 4 )) ||
```

- [ ] **Step 4: Patch MoltenVK check**

In each file, find:

```c
        else if (!strcmp( backend, "dxvk" ))
        {
```

Replace with:

```c
        else if (!strcmp( backend, "dxvk" ) || !strcmp( backend, "dxvk2" ))
        {
```

Do **not** change the `snprintf(..., "%s/lib/%s", root, backend)` path — `dxvk2` already resolves to `lib/dxvk2`.

If a patch hunk context fails later `git apply`, keep the C identical and only adjust surrounding `@@` context to match that tree.

- [ ] **Step 5: Re-run tests**

```bash
bash tests/test-cyder-graphics-prepend-patch.sh
bash tests/test-cyder-compatdb-wine-runtime.sh
```

Expected: both PASS (`compatdb-wine-runtime` still needs CX26 source archive + OEM wine tree as today).

- [ ] **Step 6: Commit**

```bash
git add patches/cyder-compatdb-runtime.patch \
  patches/cyder-compatdb-runtime-oem25.patch \
  tests/test-cyder-graphics-prepend-patch.sh
git commit -m "$(cat <<'EOF'
feat(compatdb): accept dxvk2 graphics backend

EOF
)"
```

In the engine repo, commit the matching patch separately if that tree is dirty for this change only.

---

### Task 2: Pack dxvk2 payload and exclude it from the engine tar

**Files:**
- Modify: `scripts/pack-graphics-payloads.sh`
- Modify: `scripts/pack-engine-artifact.sh`
- Modify: `/Users/jjc/cyder-wine-engine/scripts/pack-engine-artifact.sh` (same exclude line)
- Modify: `scripts/create-cyder-app.sh`
- Test: `tests/test-cyder-pack-graphics-payloads.sh`, `tests/test-cyder-pack-dxmt-gate.sh`, `tests/test-cyder-app-payload.sh`

**Interfaces:**
- Consumes: `ENGINE/lib/dxvk2/version` + PE tree from `build-dxvk2.sh`
- Produces: `dist/artifacts/graphics/dxvk2-<ver>.tar.zst` + `dxvk2-version.txt` + `dxvk2-artifact-sha256.txt`

- [ ] **Step 1: Fail pack tests that do not mention dxvk2**

In `tests/test-cyder-pack-graphics-payloads.sh`:

- `assert_contains "$help" "dxvk2"`
- After creating fake dxvk/dxmt trees, also:

```bash
mkdir -p "$engine/lib/dxvk2"
printf 'dxvk v2.7.1\n' >"$engine/lib/dxvk2/version"
python3 - "$engine/lib/dxvk2/d3d11.dll" <<'PY'
import struct, sys
contents = bytearray(128)
contents[:2] = b"MZ"
struct.pack_into("<I", contents, 60, 96)
contents[96:100] = b"PE\0\0"
open(sys.argv[1], "wb").write(contents)
PY
```

- Assert `dxvk2-2.7.1.tar.zst`, `dxvk2-version.txt`, `dxvk2-artifact-sha256.txt` exist.
- `assert_contains "$pack" 'pack_payload dxvk2'`
- Change stamp assert to require stamping both families, e.g. `name == dxvk || name == dxvk2` appears in the script.

In `tests/test-cyder-pack-dxmt-gate.sh`:

- `assert_contains "$engine_pack" "--exclude 'lib/dxvk2'"`
- Create `$engine/lib/dxvk2/version` + dummy PE like above.
- Assert `$artifacts/graphics/dxvk2-2.7.1.tar.zst` exists after `pack-engine-artifact.sh`.

In `tests/test-cyder-app-payload.sh`, after the existing graphics asserts:

```bash
assert_contains "$build_script" 'dxvk2-version.txt' \
  "Cyder.app packaging must require the DXVK 2 graphics sidecar"
```

- [ ] **Step 2: Run the three tests — expect FAIL**

```bash
bash tests/test-cyder-pack-graphics-payloads.sh
bash tests/test-cyder-pack-dxmt-gate.sh
bash tests/test-cyder-app-payload.sh
```

- [ ] **Step 3: Implement pack / exclude / app gate**

`scripts/pack-graphics-payloads.sh`:

- Help text: `ENGINE/lib/dxvk`, `lib/dxvk2`, `lib/dxmt`.
- After the dxvk/dxmt existence checks:

```bash
[[ -d "$ENGINE/lib/dxvk2" ]] || { echo "Missing DXVK2 payload: $ENGINE/lib/dxvk2" >&2; exit 1; }
```

- Stamp:

```bash
    if [[ "$name" == dxvk || "$name" == dxvk2 ]]; then
      python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$staged"
    fi
```

- After `pack_payload dxvk ...`:

```bash
pack_payload dxvk2 "$ENGINE/lib/dxvk2"
```

`scripts/pack-engine-artifact.sh` (both repos), next to the other excludes:

```bash
  --exclude 'lib/dxvk2' \
```

`scripts/create-cyder-app.sh` graphics gate — require dxvk2 sidecars the same way as dxvk/dxmt:

```bash
if [[ -f "$GRAPHICS_ARTIFACTS/dxvk-version.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxvk2-version.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxmt-version.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxvk-artifact-sha256.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxvk2-artifact-sha256.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxmt-artifact-sha256.txt" ]] \
   && compgen -G "$GRAPHICS_ARTIFACTS/dxvk-*.tar.zst" >/dev/null \
   && compgen -G "$GRAPHICS_ARTIFACTS/dxvk2-*.tar.zst" >/dev/null \
   && compgen -G "$GRAPHICS_ARTIFACTS/dxmt-*.tar.zst" >/dev/null; then
```

Error string: `Missing packaged DXVK/DXVK2/DXMT graphics artifacts`.

- [ ] **Step 4: Re-run the three tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(graphics): pack dxvk2 payload beside dxvk and dxmt

EOF
)"
```

---

### Task 3: Ensure-graphics and shell launch preference

**Files:**
- Modify: `scripts/cyder-ensure-graphics.sh`
- Modify: `scripts/cyder-common.sh`
- Test: `tests/test-cyder-ensure-graphics.sh`, `tests/test-cyder-settings-model.sh`

**Interfaces:**
- Consumes: `cyder_install_graphics_payload`, `cyder_replace_engine_graphics_link`
- Produces: `current-dxvk2` + `$engine/lib/dxvk2`; `CYDER_GRAPHICS_BACKEND=dxvk2` when payload exists

- [ ] **Step 1: Extend ensure + model tests**

In `tests/test-cyder-ensure-graphics.sh`, next to the dxvk/dxmt staging:

```bash
mkdir -p "$tmp/staging/dxvk2"
printf 'dxvk2 payload\n' >"$tmp/staging/dxvk2/d3d11.dll"
printf 'dxvk2-2.7.1\n' >"$tmp/staging/dxvk2/version"
tar -cf "$resources/dxvk2-2.7.1.tar.zst" -C "$tmp/staging" dxvk2
printf '2.7.1\n' >"$resources/dxvk2-version.txt"
printf '%s  %s\n' "$(shasum -a 256 "$resources/dxvk2-2.7.1.tar.zst" | awk '{print $1}')" \
  "dxvk2-2.7.1.tar.zst" >"$resources/dxvk2-artifact-sha256.txt"
```

After the first ensure, assert:

```bash
assert test -f "$runtime/graphics/dxvk2/2.7.1/d3d11.dll"
assert test -L "$runtime/graphics/current-dxvk2"
assert_eq "$(readlink "$engine/lib/dxvk2")" "../../../graphics/current-dxvk2" \
  "DXVK2 engine symlink must be relative to engine lib"
assert test -f "$engine/lib/dxvk2/d3d11.dll"
```

After the dxvk 1.2.4 upgrade, also assert `current-dxvk2` is still `dxvk2/2.7.1` (1.x update must not touch 2.x).

In `tests/test-cyder-settings-model.sh`:

```bash
assert_contains "$common" 'dxvk2)' \
  "shell preference helper must handle dxvk2"
assert_contains "$common" 'cyder_engine_has_dxvk2_payload' \
  "shell launch path must fail closed when lib/dxvk2 is missing"
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
bash tests/test-cyder-ensure-graphics.sh
bash tests/test-cyder-settings-model.sh
```

- [ ] **Step 3: Implement ensure + preference**

`scripts/cyder-ensure-graphics.sh` inside `cyder_ensure_graphics`:

```bash
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk2
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxmt
  ...
  cyder_replace_engine_graphics_link \
    "$engine/lib/dxvk2" "$runtime_root/graphics/current-dxvk2" "$engine" "$engines_root"
```

`scripts/cyder-common.sh` next to `cyder_engine_has_dxvk_payload`:

```bash
cyder_engine_has_dxvk2_payload() {
  local engine_root="$1"
  [[ -r "$engine_root/lib/dxvk2/x86_64-windows/d3d11.dll" ]]
}
```

In `cyder_apply_graphics_preference`, after the `dxvk)` branch:

```bash
    dxvk2)
      if cyder_engine_has_dxvk2_payload "$engine_root"; then
        export CYDER_GRAPHICS_PREFERENCE=dxvk2
        export CYDER_GRAPHICS_BACKEND=dxvk2 CX_GRAPHICS_BACKEND=dxvk2
      else
        echo "DXVK 2 is unavailable (engine lib/dxvk2 is missing); using default graphics backend." >&2
        export CYDER_GRAPHICS_PREFERENCE=default
        unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      fi
      ;;
```

- [ ] **Step 4: Re-run both tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(graphics): install and launch dxvk2 beside dxvk

EOF
)"
```

---

### Task 4: Settings schema 9 and launch environment

**Files:**
- Modify: `scripts/cyder_settings.swift`
- Modify: `scripts/cyder_app_main.swift`
- Test: `tests/fixtures/cyder_settings_harness.swift`, `tests/test-cyder-settings-swift.sh`, `tests/test-cyder-settings-model.sh`

**Interfaces:**
- Consumes: `CyderGraphicsBackend`, `CyderGraphicsCapabilities`, `effectiveLaunchBackend`, `environment()`
- Produces: `dxvk2` raw value; `hasDxvk2`; fail-closed launch; frame rate + HUD for both DXVK families

- [ ] **Step 1: Write failing harness / model asserts**

`tests/test-cyder-settings-model.sh`: change `schemaVersion = 8` assert to `schemaVersion = 9`, and add:

```bash
assert_contains "$settings" 'case wined3d, dxvk, dxvk2, dxmt, d3dmetal' \
  "settings enum must include dxvk2"
assert_contains "$settings" 'usesDxvkTranslation' \
  "frame-rate and HUD must share a DXVK-family helper"
```

In `tests/fixtures/cyder_settings_harness.swift`:

- Change every `schemaVersion == 8` precondition to `== 9`.
- Extend `CyderGraphicsCapabilities(...)` literals with `hasDxvk2: true` (or rely on a default if you add one — prefer explicit).
- After the existing dxvk env block, add:

```swift
        try store.update { settings in
            settings.graphicsBackend = .dxvk2
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .dxvk
            settings.dxvkHudFrametimes = true
        }
        let dxvk2Env = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            )
        )
        precondition(dxvk2Env["CYDER_GRAPHICS_BACKEND"] == "dxvk2")
        precondition(dxvk2Env["DXVK_FRAME_RATE"] == "60")
        precondition(dxvk2Env["DXVK_HUD"] == "fps,frametimes")

        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk2, hasD3DMetal: true, hasDxvk: true, hasDxvk2: false, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk2, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            ) == .dxvk2
        )
        precondition(CyderSettings.sanitizedGraphicsBackend("dxvk2") == .dxvk2)
        precondition(CyderSettings.resolvedGraphicsHud(preference: .dxvk2, requested: .dxvk) == .dxvk)
        precondition(CyderSettings.resolvedGraphicsHud(preference: .wined3d, requested: .dxvk) == .off)
```

Add a `hasDxvk2Payload` filesystem probe mirroring `hasDxvkPayload` (d3d11 under `lib/dxvk2` + MoltenVK).

- [ ] **Step 2: Run harness — expect compile FAIL or precondition FAIL**

```bash
bash tests/test-cyder-settings-model.sh
bash tests/test-cyder-settings-swift.sh
```

- [ ] **Step 3: Implement the model**

`scripts/cyder_settings.swift`:

```swift
enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`
    case wined3d, dxvk, dxvk2, dxmt, d3dmetal

    var usesDxvkTranslation: Bool { self == .dxvk || self == .dxvk2 }
}
```

```swift
struct CyderGraphicsCapabilities: Equatable {
    var hasD3DMetal: Bool
    var hasDxvk: Bool
    var hasDxvk2: Bool
    var hasDxmt: Bool
```

`current()` must pass `hasDxvk2: hasDxvk2Payload(engineRoot: engineRoot)`.

Copy `hasDxvkPayload` to `hasDxvk2Payload`, changing only the DLL path to `lib/dxvk2/x86_64-windows/d3d11.dll`.

Schema comments + `var schemaVersion = 9`, decode `guard decoded.schemaVersion <= 9`, `schemaVersion = 9` on decode and in `update`.

`effectiveLaunchBackend` add `hasDxvk2: Bool` (no default — update every call site) and:

```swift
        case .dxvk2:
            return hasDxvk2 ? .dxvk2 : nil
        case .wined3d, .dxvk, .d3dmetal:
            return preference
```

`resolvedGraphicsHud`:

```swift
        if requested == .dxvk && !preference.usesDxvkTranslation {
            return .off
        }
```

`environment()`:

```swift
        let effective = CyderSettings.effectiveLaunchBackend(
            preference: graphics.backend,
            hasD3DMetal: caps.hasD3DMetal,
            hasDxvk: caps.hasDxvk,
            hasDxvk2: caps.hasDxvk2,
            hasDxmt: caps.hasDxmt
        )
        ...
        if graphics.dxvkFrameRate == .sixty, graphics.backend.usesDxvkTranslation {
            result["DXVK_FRAME_RATE"] = "60"
        }
```

`scripts/cyder_app_main.swift` `graphicsPayloadsPresent()`:

```swift
        let dxvk2 = engine.appendingPathComponent("lib/dxvk2/x86_64-windows/d3d11.dll")
        return FileManager.default.isReadableFile(atPath: dxvk.path)
            || FileManager.default.isReadableFile(atPath: dxvk2.path)
            || FileManager.default.isReadableFile(atPath: dxmt.path)
```

Fix every other `effectiveLaunchBackend` / `CyderGraphicsCapabilities(` call (search the repo) so Swift still compiles.

- [ ] **Step 4: Re-run settings tests — expect PASS**

Also run `bash tests/test-cyder-force-settings-ui.sh` once; it will still fail on menu titles until Task 5 — that is expected. Do not weaken those asserts here.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(settings): add schema 9 dxvk2 backend

EOF
)"
```

---

### Task 5: Settings and game-library menus

**Files:**
- Modify: `scripts/cyder_settings_ui.swift`
- Modify: `scripts/cyder_game_library_ui.swift`
- Test: `tests/test-cyder-force-settings-ui.sh`

**Interfaces:**
- Consumes: `CyderGraphicsBackend.dxvk2`, `usesDxvkTranslation`, `hasDxvk2`
- Produces: 「DXVK 2」 after 「DXVK」; limiter/HUD for both; grey-out when payload missing

- [ ] **Step 1: Update UI contract tests first**

In `tests/test-cyder-force-settings-ui.sh`:

```bash
assert_contains "$ui" 'return ["預設", "D3DMetal", "DXMT", "DXVK", "DXVK 2", "WineD3D"]'
assert_contains "$library_ui" 'return ["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "DXVK 2", "WineD3D"]'
assert_contains "$ui" 'let showFrameRate = backend.usesDxvkTranslation'
assert_contains "$ui" 'let showDxvkFrametimes = backend.usesDxvkTranslation'
assert_contains "$ui" 'backend.usesDxvkTranslation' 
assert_contains "$ui" '需要已安裝的 DXVK 2 圖形元件'
assert_contains "$ui" '使用 DXVK 2.7 將 Direct3D 轉為 Vulkan'
```

Keep the existing `enableDxvkFrametimes = graphicsHudValue == .dxvk` assert (HUD enum is still `.dxvk`).

GPTK hide condition must also hide for `.dxvk2`:

```bash
assert_contains "$ui" 'backend != .dxvk && backend != .dxvk2 && backend != .wined3d && backend != .dxmt'
```

- [ ] **Step 2: Run — expect FAIL**

`bash tests/test-cyder-force-settings-ui.sh`

- [ ] **Step 3: Implement menus**

`scripts/cyder_settings_ui.swift`:

```swift
        return ["預設", "D3DMetal", "DXMT", "DXVK", "DXVK 2", "WineD3D"]
```

Index map: `0 default, 1 d3dmetal, 2 dxmt, 3 dxvk, 4 dxvk2, 5 wined3d`.

Add `canSelectDxvk2` (payload via `CyderGraphicsCapabilities.current(engineRoot:).hasDxvk2`) and `updateDxvk2MenuItemAvailability()` enabling `item(at: 4)` with tooltip `需要已安裝的 DXVK 2 圖形元件`.

`graphicsBackendValue` / `graphicsBackendIndex` must handle `.dxvk2` (if unavailable, fall back to `.default` / index 0, same pattern as DXMT).

`rebuildGraphicsHudMenu`: `if backend.usesDxvkTranslation { titles.append("DXVK HUD") }`.

`refreshGraphicsControls`:

```swift
        let showFrameRate = backend.usesDxvkTranslation
        let showDxvkFrametimes = backend.usesDxvkTranslation
        let showGptkControls = backend != .dxvk && backend != .dxvk2 && backend != .wined3d && backend != .dxmt
```

Help:

```swift
        case .dxvk2: "使用 DXVK 2.7 將 Direct3D 轉為 Vulkan，再由 MoltenVK 轉為 Metal。"
```

When leaving both DXVK families, drop HUD `.dxvk` the same way today’s `graphicsBackendValue != .dxvk` does — use `!graphicsBackendValue.usesDxvkTranslation`.

`scripts/cyder_game_library_ui.swift`:

```swift
        return ["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "DXVK 2", "WineD3D"]
```

Index map: `0 follow, 1 default, 2 d3dmetal, 3 dxmt, 4 dxvk, 5 dxvk2, 6 wined3d`.  
Grey-out DXVK 2 at item index 5. Update `graphicsBackendOverride` / `graphicsBackendIndex`.

- [ ] **Step 4: Re-run UI + settings tests — expect PASS**

```bash
bash tests/test-cyder-force-settings-ui.sh
bash tests/test-cyder-settings-swift.sh
bash tests/test-cyder-settings-model.sh
```

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(ui): add DXVK 2 graphics translation option

EOF
)"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/cyder-graphics-backends.zh-TW.md`
- Modify: `docs/build-dxvk.zh-TW.md`
- Modify: `docs/scripts.md`
- Modify: `docs/cyder-compatdb.zh-TW.md` (payload table)

**Interfaces:** none.

- [ ] **Step 1: Update user-facing graphics doc**

In the options table add:

| **dxvk2** | DXVK 2.7（Vulkan→Metal）；需已安裝 DXVK 2 runtime payload |

Runtime section: ensure also maintains `current-dxvk2` / `lib/dxvk2`. Finder skip text mentions DXVK 2 the same as DXVK.

Limiter section: 「選 **DXVK** 或 **DXVK 2** 時會出現限制幀率」.

Troubleshooting: 「DXVK 2 選項灰掉」→ 先開 Cyder.app 完成 ensure-graphics.

- [ ] **Step 2: Update build + scripts docs**

`docs/build-dxvk.zh-TW.md`: delete or rewrite 「尚未接到執行期」— pack/ensure/UI now consume `lib/dxvk2`. Keep the compile caveats.

`docs/scripts.md`: `pack-graphics-payloads.sh` / `cyder-ensure-graphics.sh` rows mention dxvk2.

`docs/cyder-compatdb.zh-TW.md` engine payload table: add `dxvk2` → `lib/dxvk2/<arch>-windows/` + MoltenVK.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
docs: document DXVK 2 payload and settings option

EOF
)"
```

---

### Task 7: Rebuild and pin engine (ship blocker)

**Files:**
- Engine repo: apply Task 1 patch (already copied), rebuild Wine, `pack-engine-artifact.sh`
- ogom: `scripts/import-engine-release.sh --apply` (or equivalent pin files under `config/`)

**Interfaces:**
- Consumes: updated `cyder-compatdb-runtime.patch`
- Produces: new `CX26.3.0-W11-Cyder0xx-*` artifact whose ntdll accepts `dxvk2`

Without this task, the App menu sets `CYDER_GRAPHICS_BACKEND=dxvk2` and Wine ignores it.

- [ ] **Step 1: Confirm engine patch matches ogom**

```bash
diff -u /Users/jjc/ogom/patches/cyder-compatdb-runtime.patch \
  /Users/jjc/cyder-wine-engine/patches/cyder-compatdb-runtime.patch
```

Expected: no diff (or only hunk-header noise with identical C).

- [ ] **Step 2: Rebuild / pack in `cyder-wine-engine`**

Follow that repo `AGENTS.md` and `docs/incremental-build-and-patches.md`. Do not ad-hoc `make` host Mach-O from ogom. After pack, confirm the engine tar has **no** `lib/dxvk`, `lib/dxmt`, or `lib/dxvk2`, and still has MoltenVK.

- [ ] **Step 3: Import pin into ogom and pack graphics from the local install tree**

```bash
bash scripts/pack-graphics-payloads.sh \
  --engine /Users/jjc/cyder-wine-engine/install/wine-cx26-x86_64 --force
```

Expected: `dist/artifacts/graphics/dxvk2-2.7.1.tar.zst` plus existing dxvk/dxmt archives.

- [ ] **Step 4: Manual smoke (after `create-cyder-app.sh`)**

- Settings shows **DXVK** and **DXVK 2**.
- DXVK → strings `v1.10.3`; DXVK 2 → `v2.7.1`; both builtin + prepend; bottle `d3d11` hash unchanged.

- [ ] **Step 5: Commit pin files only when the new engine artifact exists**

```bash
git commit -m "$(cat <<'EOF'
chore(engine): pin CompatDB build that accepts dxvk2

EOF
)"
```

---

## Self-review

**Spec coverage**

| Spec section | Task |
|--------------|------|
| §1 payload / pack / create-app / engine exclude | 2, 7 |
| §1 ensure / `current-dxvk2` / no new migration | 3 |
| §2 CompatDB `dxvk2` + MoltenVK + engine rebuild | 1, 7 |
| §3 schema 9 / enum / fail-closed / limiter / HUD | 4, 5 |
| §4 failure table | 3, 4, 5 |
| §5 automated tests | 1–5 |
| Docs | 6 |

**Placeholder scan:** no TBD. Engine rebuild is a concrete handoff to `cyder-wine-engine`, not an ogom `make` guess.

**Type consistency:** token / directory / rawValue are all `dxvk2`. HUD enum stays `.dxvk`. Helper name is `usesDxvkTranslation`.
