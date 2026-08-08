# DXMT Graphics Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship DXMT as an engine-bundled graphics backend option, remove the App-side `auto` cascade, and default all products to CompatDB `default`.

**Architecture:** Download and pin upstream DXMT v0.80 builtin tarball into both CX26 and OEM25 engines under `lib/dxmt/` (same layout CompatDB/`apply_graphics_backend` already expects). App settings expose `dxmt` and drop `auto`; launch paths set `CYDER_GRAPHICS_BACKEND=dxmt` when chosen. Pack scripts refuse engines missing DXMT payload.

**Tech Stack:** bash fetch/install, Swift AppKit settings, existing Wine CompatDB runtime (`apply_graphics_backend`), shell regression tests.

**Spec:** `docs/superpowers/specs/2026-08-08-cyder-dxmt-graphics-backend-design.md`

## Global Constraints

- DXMT source: `https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz`
- SHA-256: `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`
- Install layout: `lib/dxmt/{i386,x86_64}-windows/*.dll` + `lib/dxmt/x86_64-unix/winemetal.so` + `lib/dxmt/version`
- Engines: CX26 **and** MapleStory OEM25 both get the same payload
- Never borrow `/Applications/CrossOver.app/.../lib/dxmt`
- Never pack `apple_gptk`
- Remove `auto` /「自動」 entirely; legacy `"auto"` migrates to `"default"`
- `CyderProduct.defaultGraphicsBackend` is always `.default` (OEM included)
- Final backend `default` → do not set `CYDER_GRAPHICS_BACKEND`
- Final backend `wined3d|dxvk|dxmt|d3dmetal` → set `CYDER_GRAPHICS_BACKEND` (+ `CX_GRAPHICS_BACKEND`)
- `dxmt` UI requires macOS ≥ 14 and engine DXMT payload
- DXVK frame-rate UI / `DXVK_FRAME_RATE` only when effective preference is manual `dxvk`
- v0.80 is MIT (last MIT release); do not silently upgrade to post-LGPL without a new decision

## File map

| File | Responsibility |
|---|---|
| `scripts/fetch-dxmt.sh` (create, ogom) | Download, checksum, normalize into `ENGINE/lib/dxmt/` |
| `tests/test-cyder-dxmt-fetch.sh` (create) | Checksum failure + layout install (fixture tarball) |
| `scripts/cyder_settings.swift` | Enum, capabilities, sanitize/migration, resolve/env |
| `tests/fixtures/cyder_settings_harness.swift` | Settings resolution regressions |
| `scripts/cyder_settings_ui.swift` | Global graphics menu + help/availability |
| `scripts/cyder_game_library_ui.swift` | Per-game graphics override menu |
| `tests/test-cyder-force-settings-ui.sh` | Static UI contract strings |
| `scripts/cyder-common.sh` | Load settings / resolve / per-game override for `dxmt`; delete auto cascade |
| `scripts/pack-engine-artifact.sh` (ogom) | Fail closed without DXMT key files |
| `../cyder-wine-engine/scripts/pack-engine-artifact.sh` | Same pack gate (canonical engine pack) |
| `docs/cyder-graphics-backends.zh-TW.md`, READMEs | User-facing status |

---

### Task 1: `fetch-dxmt.sh` + layout test

**Files:**
- Create: `scripts/fetch-dxmt.sh`
- Create: `tests/test-cyder-dxmt-fetch.sh`
- Modify: `tests/run.sh` (only if tests are not auto-discovered by `test-*.sh` glob — match existing pattern)

**Interfaces:**
- Consumes: pinned URL + SHA-256 from Global Constraints
- Produces: `bash scripts/fetch-dxmt.sh --engine /abs/path [--also-engine /abs/path] [--cache-dir PATH] [--tarball PATH] [--dry-run]`
  - Exit 0 only when each engine has readable:
    - `lib/dxmt/x86_64-windows/d3d11.dll`
    - `lib/dxmt/x86_64-windows/dxgi.dll`
    - `lib/dxmt/x86_64-unix/winemetal.so`
    - `lib/dxmt/version` containing `v0.80` and the checksum
  - `--tarball PATH` skips download (tests / offline); still verifies checksum unless `--skip-checksum` is **not** offered (always verify)

- [ ] **Step 1: Write the failing test**

Create `tests/test-cyder-dxmt-fetch.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

SCRIPT="$ROOT/scripts/fetch-dxmt.sh"
assert test -x "$SCRIPT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxmt-fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Bad checksum must fail before mutating engine.
E1="$TMP/engine1"
mkdir -p "$E1"
printf 'not-dxmt\n' >"$TMP/bad.tar.gz"
if bash "$SCRIPT" --engine "$E1" --tarball "$TMP/bad.tar.gz" 2>"$TMP/err"; then
  echo "expected checksum failure" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/err")" "checksum" "fetch must reject bad checksum"
assert test ! -e "$E1/lib/dxmt/x86_64-unix/winemetal.so"

# Minimal fake upstream layout → normalize into lib/dxmt.
STAGE="$TMP/stage"
mkdir -p \
  "$STAGE/x86_64-windows" \
  "$STAGE/i386-windows" \
  "$STAGE/x86_64-unix"
printf 'd3d11\n' >"$STAGE/x86_64-windows/d3d11.dll"
printf 'dxgi\n' >"$STAGE/x86_64-windows/dxgi.dll"
printf 'd3d11-32\n' >"$STAGE/i386-windows/d3d11.dll"
printf 'dxgi-32\n' >"$STAGE/i386-windows/dxgi.dll"
printf 'so\n' >"$STAGE/x86_64-unix/winemetal.so"
printf 'MIT\n' >"$STAGE/LICENSE"
(
  cd "$STAGE"
  tar -czf "$TMP/good.tar.gz" .
)
# Rewrite script pin for test by computing sha of good.tar.gz is wrong —
# instead: test uses a wrapper env CYDER_DXMT_SHA256 override supported by fetch-dxmt.sh.
GOOD_SHA="$(shasum -a 256 "$TMP/good.tar.gz" | awk '{print $1}')"
E2="$TMP/engine2"
E3="$TMP/engine3"
mkdir -p "$E2" "$E3"
CYDER_DXMT_SHA256="$GOOD_SHA" CYDER_DXMT_VERSION=v0.80-test \
  bash "$SCRIPT" --engine "$E2" --also-engine "$E3" --tarball "$TMP/good.tar.gz"

for eng in "$E2" "$E3"; do
  assert test -f "$eng/lib/dxmt/x86_64-windows/d3d11.dll"
  assert test -f "$eng/lib/dxmt/x86_64-windows/dxgi.dll"
  assert test -f "$eng/lib/dxmt/x86_64-unix/winemetal.so"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "v0.80" "version pin file must record DXMT version"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "$GOOD_SHA" "version pin file must record checksum"
done

echo "PASS test-cyder-dxmt-fetch"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-dxmt-fetch.sh`  
Expected: FAIL (`fetch-dxmt.sh` missing or not executable)

- [ ] **Step 3: Implement `scripts/fetch-dxmt.sh`**

```bash
#!/usr/bin/env bash
# Fetch pinned upstream DXMT and install into Wine engine lib/dxmt/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DXMT_VERSION="${CYDER_DXMT_VERSION:-v0.80}"
DXMT_URL="${CYDER_DXMT_URL:-https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz}"
DXMT_SHA256="${CYDER_DXMT_SHA256:-8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d}"
CACHE_DIR="${CYDER_DXMT_CACHE:-$ROOT/tools/caches/dxmt}"
ENGINE=""
ALSO_ENGINES=()
TARBALL=""
DRY_RUN=0

# parse --engine / --also-engine / --cache-dir / --tarball / --dry-run / -h

run() { if (( DRY_RUN )); then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

verify_sha256() {
  local file="$1" expect="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expect" ]]; then
    echo "DXMT checksum mismatch for $file" >&2
    echo "  expected: $expect" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

# find_payload_root EXTRACT_DIR → prints dir that contains x86_64-unix/winemetal.so
# (handles tarball nesting: ".", "dxmt/", "usr/lib/dxmt/", etc.)

install_dxmt_into_engine() {
  local dest="$1" payload="$2"
  [[ "$dest" == /* ]] || { echo "Engine path must be absolute: $dest" >&2; return 1; }
  run mkdir -p "$dest/lib/dxmt"
  run rm -rf "$dest/lib/dxmt"
  run mkdir -p "$dest/lib/dxmt"
  run cp -R "$payload/." "$dest/lib/dxmt/"
  # Ensure unix so is under lib/dxmt/x86_64-unix/ even if tarball used lib/wine layout:
  # if winemetal.so found elsewhere under payload, copy into x86_64-unix/.
  cat >"$dest/lib/dxmt/version" <<EOF
dxmt ${DXMT_VERSION}
source ${DXMT_URL}
sha256 ${DXMT_SHA256}
EOF
  [[ -f "$dest/lib/dxmt/x86_64-windows/d3d11.dll" ]] || return 1
  [[ -f "$dest/lib/dxmt/x86_64-windows/dxgi.dll" ]] || return 1
  [[ -f "$dest/lib/dxmt/x86_64-unix/winemetal.so" ]] || return 1
}

# Main: resolve tarball (download into CACHE_DIR if needed) → verify_sha256 →
# extract to temp → find_payload_root → install into ENGINE + ALSO_ENGINES
```

Normalization rules (implement fully in the script, not as comments-only):

1. Prefer a directory that already has `x86_64-unix/winemetal.so` next to `x86_64-windows/`.
2. Else if `winemetal.so` lives under `**/x86_64-unix/` and DLLs under `**/x86_64-windows/`, copy those three trees into a staging `lib/dxmt`-shaped dir.
3. Else fail with a clear error listing what was found.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-cyder-dxmt-fetch.sh`  
Expected: `PASS test-cyder-dxmt-fetch`

- [ ] **Step 5: (Optional on a networked machine) Install into real engines**

```bash
bash scripts/fetch-dxmt.sh \
  --engine "$PWD/install/wine-cx26-x86_64" \
  --also-engine "$PWD/install/wine-maplestory-oem25-source-x86_64"
```

If an install tree is missing, skip with a printed note; do not fail the task commit.

- [ ] **Step 6: Commit**

```bash
git add scripts/fetch-dxmt.sh tests/test-cyder-dxmt-fetch.sh
git commit -m "$(cat <<'EOF'
feat(graphics): fetch and install pinned DXMT into engine lib/dxmt

EOF
)"
```

---

### Task 2: Settings model — add `dxmt`, remove `auto`

**Files:**
- Modify: `scripts/cyder_settings.swift`
- Modify: `tests/fixtures/cyder_settings_harness.swift`
- Run via: existing `tests/test-cyder-settings-swift.sh` (or whatever compiles the harness — keep the same runner)

**Interfaces:**
- Consumes: Task 1 not required
- Produces:
  - `enum CyderGraphicsBackend: String, Codable, CaseIterable { case \`default\`, wined3d, dxvk, dxmt, d3dmetal }`
  - `CyderProduct.defaultGraphicsBackend == .default` always
  - `sanitizedGraphicsBackend("auto") == .default`
  - `sanitizedOptionalGraphicsBackend("auto") == .default` (or `nil` is wrong — must be `.default` when raw is the string `auto`)
  - `CyderGraphicsCapabilities` gains `hasDxmt: Bool`
  - `hasDxmtPayload(engineRoot:)` checks `lib/dxmt/x86_64-windows/d3d11.dll` + `lib/dxmt/x86_64-unix/winemetal.so`
  - `effectiveLaunchBackend` cases: `default` → `nil`; concrete backends including `dxmt` → themselves; **no** `auto` / OEM cascade
  - Remove `cascadePreferredBackend`

- [ ] **Step 1: Update harness expectations (failing)**

In `tests/fixtures/cyder_settings_harness.swift`:

- Delete all `.auto` / `cascadePreferredBackend` assertions.
- OEM block becomes:

```swift
setenv("CYDER_OEM_FLAVOR", "maplestory", 1)
defer { unsetenv("CYDER_OEM_FLAVOR") }
precondition(CyderProduct.isMapleStoryOEM)
precondition(CyderProduct.defaultGraphicsBackend == .default)
let oemDefaults = CyderSettings()
precondition(oemDefaults.graphicsBackend == .default)
precondition(
    CyderSettings.effectiveLaunchBackend(
        preference: .default, hasD3DMetal: false, hasDxvk: true, hasDxmt: true
    ) == nil
)
precondition(
    CyderSettings.effectiveLaunchBackend(
        preference: .dxmt, hasD3DMetal: false, hasDxvk: true, hasDxmt: true
    ) == .dxmt
)
precondition(CyderSettings.sanitizedGraphicsBackend("auto") == .default)
```

- Update every `CyderGraphicsCapabilities(...)` / `effectiveLaunchBackend(...)` call site to pass `hasDxmt:`.
- Where env previously expected auto→dxvk, change those cases to explicit `.dxvk` preference tests only.

- [ ] **Step 2: Run harness to verify it fails**

Run the existing settings Swift test entrypoint (same command `tests/test-cyder-settings-swift.sh` or project equivalent).  
Expected: compile and/or precondition failures around `.auto` / missing `hasDxmt`.

- [ ] **Step 3: Implement settings changes**

Minimal shape:

```swift
enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`
    case wined3d, dxvk, dxmt, d3dmetal
}

static var defaultGraphicsBackend: CyderGraphicsBackend { .default }

static func sanitizedGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend {
    guard let raw else { return CyderProduct.defaultGraphicsBackend }
    if raw == "auto" { return .default }
    guard let value = CyderGraphicsBackend(rawValue: raw) else {
        return CyderProduct.defaultGraphicsBackend
    }
    return value
}

static func sanitizedOptionalGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend? {
    guard let raw else { return nil }
    if raw == "auto" { return .default }
    return CyderGraphicsBackend(rawValue: raw)
}

static func effectiveLaunchBackend(
    preference: CyderGraphicsBackend,
    hasD3DMetal: Bool,
    hasDxvk: Bool,
    hasDxmt: Bool
) -> CyderGraphicsBackend? {
    switch preference {
    case .default:
        return nil
    case .wined3d, .dxvk, .dxmt, .d3dmetal:
        return preference
    }
}

static func hasDxmtPayload(engineRoot: URL?) -> Bool {
    // Mirror hasDxvkPayload path resolution; require:
    // lib/dxmt/x86_64-windows/d3d11.dll and lib/dxmt/x86_64-unix/winemetal.so
}
```

Also update `resolveGraphics` to **not** rewrite OEM `default`→`auto`.  
Update `environment(...)` / any switch on backend to include `.dxmt` and drop `.auto`.  
Update `CyderGraphicsCapabilities.current` to set `hasDxmt`.

- [ ] **Step 4: Run harness to verify it passes**

Expected: `PASS cyder-settings-harness`

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_settings.swift tests/fixtures/cyder_settings_harness.swift
git commit -m "$(cat <<'EOF'
feat(settings): add dxmt backend and drop auto cascade

EOF
)"
```

---

### Task 3: Preferences + game-library UI

**Files:**
- Modify: `scripts/cyder_settings_ui.swift`
- Modify: `scripts/cyder_game_library_ui.swift`
- Modify: `tests/test-cyder-force-settings-ui.sh`

**Interfaces:**
- Consumes: `CyderGraphicsBackend` from Task 2; `CyderGraphicsCapabilities.hasDxmt`
- Produces: menus without「自動」; with「DXMT」; unified titles for OEM and official (both include「預設」)

- [ ] **Step 1: Update static UI contract test (failing)**

In `tests/test-cyder-force-settings-ui.sh` replace auto/OEM-specific expectations:

```bash
assert_contains "$ui" 'return ["預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]' \
  "prefs graphics labels include DXMT and omit auto"
assert_not_contains "$ui" '"自動"' "graphics menus must not offer auto"
assert_contains "$ui" "canSelectDxmt" "DXMT should gate on OS + payload"
assert_contains "$ui" "需要 macOS 14+" "DXMT/D3DMetal should explain macOS 14+"
assert_contains "$ui" 'case .dxmt:' "help text must cover DXMT"
assert_not_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'cascadePreferredBackend' \
  "auto cascade helper must be removed"
assert_contains "$library_ui" 'return ["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]' \
  "game override menus include DXMT and omit auto"
# Remove or invert:
# assert_contains ... "OEM prefs should omit CompatDB-follow graphics option"
# assert_contains ... OEM short labels with 自動
```

Also update `showGptkControls` expectation if the test asserts the expression — GPTK controls must hide for `dxmt`:

```bash
assert_contains "$ui" 'backend != .dxvk && backend != .wined3d && backend != .dxmt' \
  "GPTK controls hide for DXVK/WineD3D/DXMT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-force-settings-ui.sh`  
Expected: FAIL on new string assertions

- [ ] **Step 3: Implement UI**

`cyder_settings_ui.swift` (global):

```swift
private var canSelectDxmt: Bool {
    supportsD3DMetalOS && CyderGraphicsCapabilities.current(
        engineRoot: /* existing engine probe if available, else nil → treat like DXVK default true only when no root; prefer real root when prefs have one */
    ).hasDxmt
}

private var graphicsBackendTitles: [String] {
    ["預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]
}

// Index map (same for OEM + official):
// 0 default, 1 d3dmetal, 2 dxmt, 3 dxvk, 4 wined3d

private func updateDxmtMenuItemAvailability() { /* enable iff canSelectDxmt; tooltip macOS 14+ or missing lib/dxmt */ }

graphicsHelp:
case .dxmt: "使用 DXMT 將 Direct3D 直接轉為 Metal；需要 macOS 14+ 與引擎內建 DXMT。"

showGptkControls = backend != .dxvk && backend != .wined3d && backend != .dxmt
```

`cyder_game_library_ui.swift`:

```swift
["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]
// indices: 0 nil/follow, 1 default, 2 d3dmetal, 3 dxmt, 4 dxvk, 5 wined3d
```

Remove all `CyderProduct.isMapleStoryOEM` branches that only existed to hide「預設」or show「自動」.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-cyder-force-settings-ui.sh`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_settings_ui.swift scripts/cyder_game_library_ui.swift tests/test-cyder-force-settings-ui.sh
git commit -m "$(cat <<'EOF'
feat(ui): expose DXMT and remove graphics auto option

EOF
)"
```

---

### Task 4: Shell launch path (`cyder-common.sh`)

**Files:**
- Modify: `scripts/cyder-common.sh`
- Modify: any shell tests that assert `auto` cascade (grep `CYDER_GRAPHICS_BACKEND` / `auto` under `tests/` and update)

**Interfaces:**
- Consumes: settings JSON `graphicsBackend` values from Task 2
- Produces: `dxmt` exported like `dxvk`; no `auto` branch; OEM `default` does **not** rewrite to cascade

- [ ] **Step 1: Write/adjust a focused shell assertion**

If `tests/test-cyder-game-launch-settings.sh` (or crossover bottle conf) encodes `auto`, update to `dxmt` case:

```bash
# Prefer extending an existing graphics env test:
# when settings graphicsBackend=dxmt → environment contains CYDER_GRAPHICS_BACKEND=dxmt
```

Add assert in an existing static test if no runtime fixture:

```bash
assert_contains "$common" 'wined3d|dxvk|dxmt|d3dmetal' \
  "shell settings loader must accept dxmt"
assert_not_contains "$common" 'preference=auto' \
  "OEM must not rewrite default to auto"
```

(Search exact strings after editing — assert on the real final code.)

- [ ] **Step 2: Run the chosen test — expect fail**

- [ ] **Step 3: Patch `cyder-common.sh`**

Locations to change (all of them):

1. Settings load `case` (~line 732): `wined3d|dxvk|dxmt|d3dmetal)` — **delete** the `auto)` cascade block.
2. `cyder_resolve_effective_graphics_backend`: delete OEM `default`→`auto` rewrite and the entire `auto)` case; extend concrete case with `dxmt`.
3. Per-game JSON override `graphicsBackend` case (~2254): add `dxmt`; `default` only unsets; remove treating `auto` as a preference that clears backend (map `auto`→treat as `default` if still seen).
4. Any other `wined3d|dxvk|d3dmetal` pattern in this file — include `dxmt`.

- [ ] **Step 4: Re-run tests — expect pass**

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder-common.sh tests/
git commit -m "$(cat <<'EOF'
feat(launch): wire dxmt graphics backend and drop shell auto cascade

EOF
)"
```

---

### Task 5: Pack gates (ogom + cyder-wine-engine)

**Files:**
- Modify: `scripts/pack-engine-artifact.sh` (ogom)
- Modify: `/Users/jjc/cyder-wine-engine/scripts/pack-engine-artifact.sh`
- Modify: `tests/test-cyder-force-settings-ui.sh` **or** add `tests/test-cyder-pack-dxmt-gate.sh` in ogom that greps the pack script
- Create (engine repo): `tests/test-pack-engine-dxmt-gate.sh` that asserts the gate strings exist (no full pack required)

**Interfaces:**
- Consumes: Task 1 layout paths
- Produces: pack fails closed unless these exist under `ENGINE_TREE`:
  - `lib/dxmt/x86_64-windows/d3d11.dll`
  - `lib/dxmt/x86_64-windows/dxgi.dll`
  - `lib/dxmt/x86_64-unix/winemetal.so`

- [ ] **Step 1: Add failing grep tests**

ogom:

```bash
assert_contains "$(cat "$ROOT/scripts/pack-engine-artifact.sh")" 'lib/dxmt/x86_64-unix/winemetal.so' \
  "engine pack must require DXMT winemetal.so"
```

cyder-wine-engine:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
assert_contains "$pack" 'lib/dxmt/x86_64-windows/d3d11.dll'
assert_contains "$pack" 'lib/dxmt/x86_64-unix/winemetal.so'
echo "PASS test-pack-engine-dxmt-gate"
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Add gates next to existing DXVK loops**

Both pack scripts, after the DXVK check:

```bash
for _dxmt_file in \
  lib/dxmt/x86_64-windows/d3d11.dll \
  lib/dxmt/x86_64-windows/dxgi.dll \
  lib/dxmt/x86_64-unix/winemetal.so; do
  if [[ ! -f "$ENGINE_TREE/$_dxmt_file" ]]; then
    echo "Refusing to pack engine without $_dxmt_file (run scripts/fetch-dxmt.sh)" >&2
    exit 1
  fi
done
unset _dxmt_file
```

(In cyder-wine-engine, message may say `ogom scripts/fetch-dxmt.sh` or document both paths — keep message actionable.)

- [ ] **Step 4: Run grep tests — expect pass**

- [ ] **Step 5: Commit in each repo**

ogom:

```bash
git add scripts/pack-engine-artifact.sh tests/
git commit -m "$(cat <<'EOF'
build(engine): require DXMT payload in pack-engine-artifact

EOF
)"
```

cyder-wine-engine:

```bash
git add scripts/pack-engine-artifact.sh tests/test-pack-engine-dxmt-gate.sh
git commit -m "$(cat <<'EOF'
build(engine): require DXMT payload in pack-engine-artifact

EOF
)"
```

---

### Task 6: User docs

**Files:**
- Modify: `docs/cyder-graphics-backends.zh-TW.md`
- Modify: `README.md` (graphics backend status table)
- Modify: `README.zh-TW.md` (same)

**Interfaces:**
- Consumes: finished behavior from Tasks 1–5
- Produces: docs matching shipped options

- [ ] **Step 1: Update docs**

`docs/cyder-graphics-backends.zh-TW.md`:

- Title/options table: add **dxmt**; remove any「自動」if present.
- Note: DXMT ships in engine `lib/dxmt` (v0.80); needs macOS 14+.
- Keep D3DMetal/GPTK section unchanged in spirit.

READMEs: change dxmt row from「尚未整合 / Not integrated」to integrated / shipped in engine payload.

- [ ] **Step 2: Quick skim for contradictions** (`auto` + dxmt「未整合」)

- [ ] **Step 3: Commit**

```bash
git add docs/cyder-graphics-backends.zh-TW.md README.md README.zh-TW.md
git commit -m "$(cat <<'EOF'
docs(graphics): document DXMT option and drop auto backend

EOF
)"
```

---

## Self-review (author)

| Spec requirement | Task |
|---|---|
| Pin v0.80 + checksum into `lib/dxmt` | Task 1 |
| Both CX26 + OEM25 | Task 1 (`--also-engine`) |
| No CrossOver borrow | Task 1 + Global Constraints |
| UI option `dxmt` | Task 3 |
| Remove `auto`; default `default` | Tasks 2–4 |
| Launch `CYDER_GRAPHICS_BACKEND=dxmt` | Task 4 |
| Pack gate | Task 5 |
| Docs | Task 6 |
| macOS 14 gate | Task 3 |
| MIT v0.80 only | Global Constraints + Task 1 pin |

No TBD placeholders. Method names (`hasDxmtPayload`, `canSelectDxmt`, `fetch-dxmt.sh`) are consistent across tasks.
