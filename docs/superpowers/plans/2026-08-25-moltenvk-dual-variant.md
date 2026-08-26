# MoltenVK Dual Variant + Wait-Poll Shim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship MoltenVK 1.4.2 and 1.2.10 in the engine tarball, keep a fixed wait-poll shim as `libMoltenVK.dylib`, and let Cyder flip `libMoltenVK.real.dylib` by global preference (`1.4.2` \| `1.2.10`) with macOS &lt; 12 forced to 1.2.10.

**Architecture:** Engine owns both versioned real dylibs + prebuilt wait-poll shim + default `.real` symlink. Cyder resolves the variant from macOS + `settings.json`, then idempotently rewrites only the `.real` symlink on ensure / settings save / Wine launch. Timeline-wait stays in the shim (not source-patched into either real). Capability + present patches remain on the 1.4.2 real build only.

**Tech Stack:** Bash (engine pack / Cyder ensure), Python (`pack-minos-scan.py`), Swift settings UI, Apple clang x86_64 re-export shim, MoltenVK upstream 1.4.2 + crossover-foss 1.2.10.

**Spec:** `docs/superpowers/specs/2026-08-25-moltenvk-dual-variant-design.md`

## Global Constraints

- Product host minOS floor remains **10.15** for Wine and all host Mach-O except listed exemptions.
- Only `lib/wine/x86_64-unix/libMoltenVK-1.4.2.dylib` may declare minos up to **12.0**.
- Preference values are exactly `1.4.2` and `1.2.10` (no `auto`).
- Preference is **global** only.
- Both reals must **not** include `cyder-moltenvk-timeline-wait-poll.patch`; shim provides ports fix.
- Do not redistribute `/Applications/CrossOver.app/.../libMoltenVK.dylib`; build from crossover-foss / pinned sources.
- Engine work lives in `/Users/jjc/cyder-wine-engine`; app work in `/Users/jjc/ogom`.
- Conventional Commits; do not commit unless the user asks (or the execution skill’s per-task commit step is explicitly approved for that session).

## File map

| Path | Responsibility |
|------|----------------|
| `cyder-wine-engine/tools/cyder-mvk-timeline-wait-poll/*` | Restore shim `.m` + `install-shim.sh` from git history; pack-time install into unix lib |
| `cyder-wine-engine/scripts/ensure-moltenvk-source.sh` | Pin **1.4.2** SHA-256 |
| `cyder-wine-engine/scripts/env-x86_64.sh` | Default `MOLTENVK_VERSION=1.4.2` |
| `cyder-wine-engine/scripts/build-graphics-stack.sh` | Build 1.4.2 without timeline-wait; stop writing single `libMoltenVK.dylib` as the only artifact |
| `cyder-wine-engine/scripts/install-moltenvk-dual-variant.sh` (**new**) | Stage versioned reals + shim + `.real` into graphics/engine unix lib |
| `cyder-wine-engine/scripts/bundle-wine-dylibs.sh` | Copy dual layout into engine tree |
| `cyder-wine-engine/scripts/pack-minos-scan.py` | Exempt `libMoltenVK-1.4.2.dylib` to 12.0 |
| `cyder-wine-engine/scripts/pack-engine-artifact.sh` | Require dual + shim pair for Cyder012+ labels |
| `cyder-wine-engine/patches/README.md`, `docs/integration-with-cyder.md`, workflow docs | Flip Cyder011 “no `.real`” contract |
| `ogom/scripts/cyder-moltenvk-variant.sh` (**new**) | `resolve` + `apply` symlink helpers |
| `ogom/scripts/cyder-common.sh`, `cyder-macos-compat.sh` | Call apply on ensure / launch |
| `ogom/scripts/cyder_settings.swift`, `cyder_settings_ui.swift` | Schema + UI picker |
| `ogom/scripts/cyder_app_main.swift` | Apply on settings save / ensureEnvironment |
| Engine + ogom `tests/test-*.sh` | Contract tests |

**Suggested engine label:** `CX26.3.0-W11-Cyder012` (or next free Cyder N).

---

### Task 1: Restore wait-poll shim tools in cyder-wine-engine

**Files:**
- Create (restore from `a45977c`): `cyder-wine-engine/tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m`
- Create (restore): `cyder-wine-engine/tools/cyder-mvk-timeline-wait-poll/install-shim.sh`
- Test: `cyder-wine-engine/tests/test-moltenvk-wait-poll-shim-tool.sh` (**new**)

**Interfaces:**
- Produces: `bash tools/cyder-mvk-timeline-wait-poll/install-shim.sh` builds shim into `build/cyder-mvk-timeline-wait-poll/libMoltenVK.dylib` with marker `cyder-moltenvk-timeline-wait-poll` and re-export `@loader_path/libMoltenVK.real.dylib`

- [ ] **Step 1: Restore files from history**

```bash
cd /Users/jjc/cyder-wine-engine
git checkout a45977c -- \
  tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m \
  tools/cyder-mvk-timeline-wait-poll/install-shim.sh
```

- [ ] **Step 2: Write failing tool smoke test**

```bash
#!/usr/bin/env bash
# tests/test-moltenvk-wait-poll-shim-tool.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"
assert test -f "$ROOT/tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m"
assert test -f "$ROOT/tools/cyder-mvk-timeline-wait-poll/install-shim.sh"
assert_contains "$(cat "$ROOT/tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m")" \
  "cyder-moltenvk-timeline-wait-poll" \
  "shim source must embed the wait-poll marker string"
```

- [ ] **Step 3: Run test**

Run: `bash tests/test-moltenvk-wait-poll-shim-tool.sh`  
Expected: PASS after restore

- [ ] **Step 4: Wire into `tests/run.sh`**

Add `test-moltenvk-wait-poll-shim-tool.sh` next to the existing timeline-wait patch test.

- [ ] **Step 5: Commit** (when user approves commits)

```bash
git add tools/cyder-mvk-timeline-wait-poll tests/test-moltenvk-wait-poll-shim-tool.sh tests/run.sh
git commit -m "$(cat <<'EOF'
chore(moltenvk): restore wait-poll shim tooling for dual-variant engines

EOF
)"
```

---

### Task 2: Pin upstream MoltenVK 1.4.2 (no timeline-wait in source build)

**Files:**
- Modify: `cyder-wine-engine/scripts/env-x86_64.sh` (`MOLTENVK_VERSION` default)
- Modify: `cyder-wine-engine/scripts/ensure-moltenvk-source.sh` (SHA + version marker)
- Modify: `cyder-wine-engine/scripts/build-graphics-stack.sh` (patch list: capability + present only)
- Modify: `cyder-wine-engine/tests/test-moltenvk-1-4-source-and-capabilities.sh`
- Modify: `cyder-wine-engine/patches/README.md` (document shim vs source split)

**Interfaces:**
- Produces: `MOLTENVK_VERSION=1.4.2`, SHA-256 `6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb` for the GitHub `v1.4.2` source tarball
- Produces: graphics build applies only:
  - `cyder-moltenvk-crossover-capability-hacks.patch`
  - `cyder-moltenvk-present-autoreleasepool.patch`
- Consumes: Task 1 shim tools exist (not applied in this task)

- [ ] **Step 1: Update failing pin test expectations to 1.4.2**

In `tests/test-moltenvk-1-4-source-and-capabilities.sh`, change assertions from `1.4.0` / patch `0` to `1.4.2` / patch `2`, and expect `ensure-moltenvk-source.sh` dry-run URL `v1.4.2`.

- [ ] **Step 2: Run test (expect FAIL)**

Run: `bash tests/test-moltenvk-1-4-source-and-capabilities.sh`  
Expected: FAIL on version string / SHA case

- [ ] **Step 3: Implement pin**

```bash
# env-x86_64.sh
export MOLTENVK_VERSION="${MOLTENVK_VERSION:-1.4.2}"
```

```bash
# ensure-moltenvk-source.sh case arm
  1.4.2)
    MOLTENVK_SHA256="${MOLTENVK_SHA256:-6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb}"
    ;;
  1.4.0)
    # keep for comparison builds if desired
    MOLTENVK_SHA256="${MOLTENVK_SHA256:-fc74aef926ee3cd473fe260a93819c09fdc939bff669271a587e9ebaa43d4306}"
    ;;
```

Update header version checks (`MVK_VERSION_PATCH` → `2`).

In `build-graphics-stack.sh`, remove `cyder-moltenvk-timeline-wait-poll.patch` from the applied list and from the `version` stamp line; keep capability + present. Document that ports fix is the shim.

Rebase capability/present patches onto 1.4.2 if `patch` fails; keep intent identical.

- [ ] **Step 4: Re-run pin test**

Run: `bash tests/test-moltenvk-1-4-source-and-capabilities.sh`  
Expected: PASS

- [ ] **Step 5: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(moltenvk): pin upstream 1.4.2 without timeline-wait source patch

EOF
)"
```

---

### Task 3: Dual-variant install layout + pack validation

**Files:**
- Create: `cyder-wine-engine/scripts/install-moltenvk-dual-variant.sh`
- Modify: `cyder-wine-engine/scripts/build-graphics-stack.sh` (call installer after builds)
- Modify: `cyder-wine-engine/scripts/bundle-wine-dylibs.sh` (prefer versioned names)
- Modify: `cyder-wine-engine/scripts/pack-engine-artifact.sh` (Cyder012+ require dual + shim)
- Test: `cyder-wine-engine/tests/test-moltenvk-dual-variant-layout.sh` (**new**)

**Interfaces:**
- Produces: under unix lib (and/or `GRAPHICS_INSTALL` staging):

```text
libMoltenVK-1.4.2.dylib
libMoltenVK-1.2.10.dylib
libMoltenVK.real.dylib -> libMoltenVK-1.4.2.dylib
libMoltenVK.dylib          # wait-poll shim
```

- Consumes: Task 1 shim build; Task 2 1.4.2 real; crossover-foss 1.2.10 real at a documented path (script arg or `MOLTENVK_LEGACY_DYLIB`)

- [ ] **Step 1: Write failing layout test** (fixture with fake dylibs + real shim binary if buildable, else mock marker file checks on script source)

```bash
# Assert install-moltenvk-dual-variant.sh creates relative .real symlink
# and refuses if 1.4.2 or 1.2.10 missing.
```

Minimal fixture approach: create two tiny Mach-O or even empty placeholder files named as reals, build or copy a previously built shim, run installer into temp unix dir, assert `readlink libMoltenVK.real.dylib == libMoltenVK-1.4.2.dylib` and shim marker.

- [ ] **Step 2: Implement `install-moltenvk-dual-variant.sh`**

```bash
#!/usr/bin/env bash
# Usage: install-moltenvk-dual-variant.sh <unix-lib-dir> \
#   --v142 <libMoltenVK-1.4.2.dylib> --v1210 <libMoltenVK-1.2.10.dylib>
set -euo pipefail
# copy versioned reals, ln -sfn libMoltenVK-1.4.2.dylib libMoltenVK.real.dylib
# build/install shim as libMoltenVK.dylib via tools/.../install-shim.sh adapted
#   to operate on an explicit tree (extend install-shim.sh with --tree DIR)
```

Extend `install-shim.sh` with `--tree <engine-or-unix-parent>` so pack does not need `~/.cyder`.

**1.2.10 source path:** add `build-graphics-stack.sh --moltenvk-legacy crossover-foss` (or second invocation) that builds into `install/graphics-cx26-x86_64/lib/libMoltenVK-1.2.10.dylib` without Cyder timeline-wait. Prefer FOSS CX moltenvk tree already used by `MOLTENVK_SOURCE=crossover-foss`.

- [ ] **Step 3: Update pack-engine-artifact.sh for Cyder012+**

Replace Cyder008/009-only gate with:

```bash
if [[ "$ENGINE_VERSION_LABEL" == *Cyder012* || "$ENGINE_VERSION_LABEL" == *Cyder0[0-9][0-9]* && ... ]]; then
  # Prefer: match Cyder012 and later via numeric parse, or simply
  # always require dual layout once this lands (break Cyder011 repacks).
fi
```

Practical rule for this change: **require dual layout whenever packing the new release label**; keep a clear error if only single `libMoltenVK.dylib` without versioned siblings.

Checks:
- `-f` both versioned reals
- `-L` `.real` (or `-h`) pointing to one of them
- shim marker + re-export `.real`
- `.real` target is not itself a shim (`otool -L` / strings)

- [ ] **Step 4: Run layout + existing pack dry tests**

Run: `bash tests/test-moltenvk-dual-variant-layout.sh`  
Expected: PASS

- [ ] **Step 5: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(moltenvk): install dual 1.4.2/1.2.10 reals with wait-poll shim

EOF
)"
```

---

### Task 4: minos exemption for `libMoltenVK-1.4.2.dylib`

**Files:**
- Modify: `cyder-wine-engine/scripts/pack-minos-scan.py`
- Test: `cyder-wine-engine/tests/test-pack-minos-scan-moltenvk-exempt.sh` (**new**)
- Modify: `cyder-wine-engine/AGENTS.md` (document second exemption)

**Interfaces:**
- Produces: `minos_limit_for(rel)` returns ceiling `(12,0,0)` when basename is `libMoltenVK-1.4.2.dylib` or rel path ends with `/libMoltenVK-1.4.2.dylib`

- [ ] **Step 1: Failing test**

Create a tiny x86_64 dylib with `-mmacosx-version-min=12.0` named `libMoltenVK-1.4.2.dylib` under a fake engine tree; also create `libMoltenVK-1.2.10.dylib` with minos 14.0 (must still fail). Assert scan passes for 1.4.2 alone and fails for high-minos 1.2.10.

- [ ] **Step 2: Implement exemption next to DXMT**

```python
MOLTENVK_142_NAME = "libMoltenVK-1.4.2.dylib"
MOLTENVK_142_CEILING = (12, 0, 0)

def minos_limit_for(rel_path: str, floor: tuple) -> tuple:
    if is_dxmt_exempt_path(rel_path):
        return max(floor, DXMT_MINOS_CEILING)
    if Path(rel_path).name == MOLTENVK_142_NAME:
        return max(floor, MOLTENVK_142_CEILING)
    return floor
```

- [ ] **Step 3: Run test**

Run: `bash tests/test-pack-minos-scan-moltenvk-exempt.sh`  
Expected: PASS

- [ ] **Step 4: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(pack): allow MoltenVK 1.4.2 dylib minos up to 12.0

EOF
)"
```

---

### Task 5: Engine docs + contract flip (no longer forbid `.real`)

**Files:**
- Modify: `cyder-wine-engine/docs/integration-with-cyder.md`
- Modify: `cyder-wine-engine/docs/build-engine-from-scratch.zh-TW.md`
- Modify: `cyder-wine-engine/docs/engine-development-test-workflow.zh-TW.md`
- Modify: `cyder-wine-engine/.agents/skills/incremental-wine-build/SKILL.md`
- Modify: `cyder-wine-engine/patches/README.md`
- Modify: `cyder-wine-engine/config/engine-release.json` notes (MoltenVK dual + shim)
- Modify matching assertions that `test ! -e .../libMoltenVK.real.dylib`

- [ ] **Step 1: Invert workflow checks**

```bash
test -f "$ENGINE/lib/wine/x86_64-unix/libMoltenVK-1.4.2.dylib"
test -f "$ENGINE/lib/wine/x86_64-unix/libMoltenVK-1.2.10.dylib"
test -L "$ENGINE/lib/wine/x86_64-unix/libMoltenVK.real.dylib"
test -f "$ENGINE/lib/wine/x86_64-unix/libMoltenVK.dylib"
strings "$ENGINE/lib/wine/x86_64-unix/libMoltenVK.dylib" | grep -q cyder-moltenvk-timeline-wait-poll
```

- [ ] **Step 2: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
docs(moltenvk): require dual-variant shim pair in engine contract

EOF
)"
```

---

### Task 6: Cyder resolve/apply helpers (ogom)

**Files:**
- Create: `ogom/scripts/cyder-moltenvk-variant.sh`
- Modify: `ogom/scripts/cyder-macos-compat.sh` (optional thin wrappers)
- Test: `ogom/tests/test-cyder-moltenvk-variant.sh` (**new**)

**Interfaces:**
- Produces:

```bash
# prints 1.4.2 or 1.2.10
cyder_resolve_moltenvk_variant <preference> # preference is 1.4.2|1.2.10
# uses cyder_macos_at_least 12 0

cyder_apply_moltenvk_variant <engine_root> <preference>
# sets lib/wine/x86_64-unix/libMoltenVK.real.dylib -> libMoltenVK-$resolved.dylib
# verifies shim marker; returns non-zero on missing files / double-shim
```

- [ ] **Step 1: Failing tests**

```bash
# Fake engine unix lib with two empty reals + fake shim file containing marker string
# CYDER_MOCK_MACOS=11.0 resolve 1.4.2 -> 1.2.10
# CYDER_MOCK_MACOS=13.0 resolve 1.2.10 -> 1.2.10
# apply twice; readlink stable; switch preference; target changes
```

Add optional `CYDER_MOCK_MACOS` only for tests (read in resolve when set).

- [ ] **Step 2: Implement script**

```bash
cyder_resolve_moltenvk_variant() {
  local pref="${1:?}"
  case "$pref" in 1.4.2|1.2.10) ;; *) echo "invalid moltenvk variant: $pref" >&2; return 2 ;; esac
  if ! cyder_macos_at_least 12 0; then
    printf '1.2.10\n'
    return 0
  fi
  printf '%s\n' "$pref"
}

cyder_apply_moltenvk_variant() {
  local engine="${1:?}" pref="${2:?}" unix resolved target
  unix="$engine/lib/wine/x86_64-unix"
  resolved="$(cyder_resolve_moltenvk_variant "$pref")"
  target="libMoltenVK-${resolved}.dylib"
  [[ -f "$unix/$target" ]] || { echo "missing $unix/$target" >&2; return 1; }
  [[ -f "$unix/libMoltenVK.dylib" ]] || return 1
  strings "$unix/libMoltenVK.dylib" | grep -Fq 'cyder-moltenvk-timeline-wait-poll' || {
    echo "libMoltenVK.dylib is not the wait-poll shim" >&2
    return 1
  }
  ln -sfn "$target" "$unix/libMoltenVK.real.dylib"
}
```

Source `cyder-macos-compat.sh` for `cyder_macos_at_least`. For mock OS in tests, gate `cyder_macos_product_version` when `CYDER_MOCK_MACOS` is set.

- [ ] **Step 3: Run test**

Run: `bash tests/test-cyder-moltenvk-variant.sh`  
Expected: PASS

- [ ] **Step 4: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(cyder): add MoltenVK variant resolve/apply helpers

EOF
)"
```

---

### Task 7: Settings schema + graphics UI

**Files:**
- Modify: `ogom/scripts/cyder_settings.swift` (schema 13, `moltenvkVariant`)
- Modify: `ogom/scripts/cyder_settings_ui.swift` (popup on 圖形 tab)
- Modify: `ogom/scripts/cyder-common.sh` (export preference from settings JSON for launchers)
- Test: existing settings decode tests if any; add `tests/test-cyder-moltenvk-settings.sh` or Swift typecheck assertions in a bash harness that greps schema

**Interfaces:**
- Produces:

```swift
enum CyderMoltenvkVariant: String, Codable, CaseIterable {
  case v142 = "1.4.2"
  case v1210 = "1.2.10"
}
// CyderSettings.moltenvkVariant
// default: ProcessInfo / sw_vers >= 12 ? .v142 : .v1210 at first init
```

- [ ] **Step 1: Bump schema to 13; add field with sanitizer**

Reject unknown strings → default by host OS (same rule as resolve).

- [ ] **Step 2: UI**

On 圖形 tab, add `NSPopUpButton` titles `MoltenVK 1.4.2` / `MoltenVK 1.2.10`.  
If host &lt; 12, disable 1.4.2 item and force selection to 1.2.10 (mirror D3DMetal greying).

Help text (Traditional Chinese): 舊 Intel 顯示異常時可改用 1.2.10；Mach Ports 修復由引擎 shim 提供。

- [ ] **Step 3: On save, call apply**

From Swift, invoke bash helper or shared C bridge already used for other ensures; prefer:

```swift
// after store.update
CyderMoltenvk.ensureVariant(preference: store.value.moltenvkVariant.rawValue)
```

implemented as `/bin/bash scripts/cyder-moltenvk-variant.sh apply …` with `CYDER_ENGINES` / engine path.

- [ ] **Step 4: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(settings): global MoltenVK 1.4.2 / 1.2.10 preference

EOF
)"
```

---

### Task 8: Wire ensure-engine and Wine launch

**Files:**
- Modify: `ogom/scripts/cyder-common.sh` (`cyder_ensure_engine` / launch path after extract+sign)
- Modify: `ogom/scripts/cyder_launcher.sh` (before wine exec)
- Modify: `ogom/scripts/cyder_app_main.swift` (`ensureEnvironment`)
- Test: extend `tests/test-cyder-moltenvk-variant.sh` or add `tests/test-cyder-moltenvk-launch-hook.sh` asserting common.sh sources/calls apply

- [ ] **Step 1: After successful engine install / when engine already present**

```bash
pref="${CYDER_MOLTENVK_VARIANT_PREFERENCE:-1.4.2}"
# Prefer reading from settings.json via existing settings export path used for graphics
cyder_apply_moltenvk_variant "$engine" "$pref" || {
  echo "MoltenVK variant apply failed" >&2
  return 1
}
```

Hook wherever `cyder_apply_graphics_preference` is already invoked so Finder EXE and app launch both get it.

- [ ] **Step 2: Grep-based contract test**

```bash
assert_contains "$(cat scripts/cyder-common.sh)" "cyder_apply_moltenvk_variant"
assert_contains "$(cat scripts/cyder_launcher.sh)" "cyder_apply_moltenvk_variant"
```

- [ ] **Step 3: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
feat(cyder): apply MoltenVK variant on ensure and launch

EOF
)"
```

---

### Task 9: ogom docs + release notes stub + manual checklist

**Files:**
- Modify: `ogom/docs/cyder.md` (MoltenVK section; shim returns)
- Modify: `ogom/README.md` / `README.zh-TW.md` MoltenVK row
- Modify: `ogom/config/cyder-engine-manifest.json` notes when pinning Cyder012
- Create or update: release notes draft when engine is actually packed

- [ ] **Step 1: Document dual layout + preference**

- [ ] **Step 2: Manual acceptance checklist** (copy from spec §3)

- [ ] **Step 3: Commit** (when approved)

```bash
git commit -m "$(cat <<'EOF'
docs: document MoltenVK dual-variant preference and shim layout

EOF
)"
```

---

### Task 10: Full engine rebuild + pack smoke (manual / CI machine)

**Files:** none new; uses prior scripts

- [ ] **Step 1:** In `cyder-wine-engine`, build graphics dual + wine bundle + pack with `CYDER_ENGINE_VERSION_LABEL=CX26.3.0-W11-Cyder012`

- [ ] **Step 2:** Verify archive contains both reals, shim, `.real`

```bash
zstd -d -c dist/artifacts/engine-….tar.zst | tar -t | rg 'MoltenVK'
```

- [ ] **Step 3:** Install into a test `~/.cyder` runtime; toggle preference; confirm `readlink` and #7-class smoke if hardware available

- [ ] **Step 4:** Pin artifact into ogom and bump app version in a follow-up release PR (out of scope unless asked)

---

## Spec coverage self-review

| Spec requirement | Task |
|------------------|------|
| Dual pack in engine tarball | 3, 10 |
| Shim + `.real` symlink select | 1, 3, 6 |
| Global `1.4.2` \| `1.2.10` only | 7 |
| &lt;12 force 1.2.10 | 6, 7 |
| No timeline-wait in reals | 2, 3 |
| Capability/present on 1.4.2 | 2 |
| minos 12 exemption for 1.4.2 only | 4 |
| Abolish Cyder011 forbid-`.real` | 5 |
| ensure / launch / settings apply | 7, 8 |
| Ports via shim | 1, 3 |
| Docs + tests | 5, 9, tests in 1–8 |

## Placeholder / consistency check

- Preference field name: `moltenvkVariant` / env `CYDER_MOLTENVK_VARIANT_PREFERENCE` — use consistently.
- Engine label: `Cyder012` unless release process chooses another; update pack gate accordingly.
- MoltenVK 1.4.2 source SHA pinned above; re-verify if GitHub retags (unlikely).
