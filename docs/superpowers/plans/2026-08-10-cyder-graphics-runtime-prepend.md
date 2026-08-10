# Cyder Graphics Runtime Prepend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch Cyder graphics backends to CrossOver-style runtime prepend (keep Wine built-in d3d* in the bottle; ship DXVK/DXMT as app graphics payloads updated on Cyder.app open).

**Architecture:** Fix CompatDB `apply_graphics_backend` so DXVK uses `b` + prepend like DXMT/CX. Stop copying DXVK/DXMT PE into prefixes. Pack DXVK/DXMT as `Resources/graphics/*.tar.zst` and install them under `~/.cyder/runtime/graphics/`, then symlink `$ENGINE/lib/dxvk` and `$ENGINE/lib/dxmt` to `current-*` so `CYDER_GRAPHICS_BACKENDS_ROOT` can remain the engine root (MoltenVK stays resolvable). Open Cyder runs `ensure-graphics` + one-shot bottle migration; Finder EXE launch skips ensure-graphics.

**Tech Stack:** bash (`cyder-common.sh`, pack/create-app), Wine ntdll CompatDB patches (`patches/cyder-compatdb-runtime*.patch` + rebuild in `cyder-wine-engine`), Swift launch path (`cyder_app_main.swift`), shell tests under `tests/`.

## Global Constraints

- Bottle `system32`/`syswow64` `d3d*`/`dxgi` remain Wine built-ins after migration; switching backends must not rewrite those PE hashes.
- DXVK/DXMT are **not** shipped inside the engine tarball; MoltenVK stays in the engine.
- GPTK missing is soft status only (does not block opening Cyder).
- Finder EXE path must not run graphics payload version install/upgrade.
- Engine pack/minOS work that rebuilds Wine belongs in `/Users/jjc/cyder-wine-engine` (see that repo `AGENTS.md`); ogom keeps matching patch copies under `patches/`.
- Conventional Commits; do not push unless asked.

## File map

| File | Responsibility |
|------|----------------|
| `patches/cyder-compatdb-runtime.patch` (+ OEM copy) | DXVK override `n,b` → `b` (match DXMT/CX prepend model) |
| `cyder-wine-engine` rebuild / pack scripts | Apply patch; stop requiring `lib/dxvk`/`lib/dxmt` inside engine archive; optional exclude |
| `scripts/pack-graphics-payloads.sh` (new) | Build `dist/artifacts/graphics/dxvk-*.tar.zst` + `dxmt-*.tar.zst` + sidecars from engine tree **before** stripping |
| `scripts/cyder-ensure-graphics.sh` (new) | Version compare, extract to `~/.cyder/runtime/graphics`, update `current-*`, symlink into engine `lib/dxvk`/`lib/dxmt` |
| `scripts/cyder-migrate-graphics-prefix.sh` (new) | Restore Wine built-in d3d* if old Cyder DXVK/DXMT PE detected |
| `scripts/cyder-common.sh` | Call ensure/migrate; remove provision-from-bootstrap; point launch backends root; Finder skip flag |
| `scripts/cyder_launcher.sh` / Swift `ensureEnvironment` | Wire `--ensure-graphics-only`; skip on document/Finder launch |
| `scripts/create-cyder-app.sh` | Bundle `Resources/graphics/`; stop relying on engine-embedded dxvk/dxmt |
| `scripts/install-dxvk-prefix.sh` / `install-dxmt-prefix.sh` | Keep for tests/migration tooling or mark deprecated no-op for production paths |
| `tests/test-cyder-graphics-*.sh` | New/updated coverage |

---

### Task 1: CompatDB — DXVK uses `b` + prepend (like DXMT)

> **Amendment (user 2026-08-10):** CrossOver DXVK PE carries the `"Wine builtin DLL"` stamp. Stock Cyder DXVK does not, so `b`+prepend alone is ignored by Wine. Task 1 also stamps DXVK PE (offset 64, 32 bytes) in `build-dxvk.sh` / install tree; loaddll smoke must show differing builtin addresses. See `.superpowers/sdd/task-1-amendment-stamp-dxvk.md`.

**Files:**
- Modify: `patches/cyder-compatdb-runtime.patch` (and `patches/cyder-compatdb-runtime-oem25.patch` if present with the same ternary)
- Modify: matching patch under `/Users/jjc/cyder-wine-engine/patches/` (authoritative rebuild source)
- Create: `scripts/stamp-wine-builtin-pe.py` (or equivalent) + wire into `scripts/build-dxvk.sh`
- Test: `tests/test-cyder-compatdb-wine-runtime.sh` and/or a new focused assert on patch text + loaddll smoke helper; stamp unit test

**Interfaces:**
- Consumes: existing `apply_graphics_backend()`, `backend_has_module()`, `prepend_dll_path()`
- Produces: DXVK branch uses load order `"b"` (same as non-dxvk backends in the ternary); DXVK PE under `lib/dxvk` is Wine-builtin-stamped like CX/DXMT

- [ ] **Step 1: Write failing test that the patch must not use `n,b` for dxvk**

Add to `tests/test-cyder-compatdb-wine-runtime.sh` (or new `tests/test-cyder-graphics-prepend-patch.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
patch="$ROOT/patches/cyder-compatdb-runtime.patch"
# DXVK must not get a special native-first override.
if grep -n 'dxvk.*n,b\|!strcmp( backend, "dxvk" ) ? "n,b"' "$patch"; then
  echo "FAIL: dxvk still uses n,b native-first override" >&2
  exit 1
fi
grep -q 'prepend_dll_path' "$patch"
echo "PASS test-cyder-graphics-prepend-patch"
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash tests/test-cyder-graphics-prepend-patch.sh`  
Expected: FAIL mentioning `n,b`

- [ ] **Step 3: Change the ternary to always use `"b"` for backend modules**

In both ogom and cyder-wine-engine patch copies, replace:

```c
if (!add_backend_override( applied, modules[i],
                           !strcmp( backend, "dxvk" ) ? "n,b" : "b" ))
```

with:

```c
if (!add_backend_override( applied, modules[i], "b" ))
```

Keep `prepend_dll_path(retained_path)` and MoltenVK / DXMT existence checks unchanged.

- [ ] **Step 4: Re-run patch test — expect PASS**

Run: `bash tests/test-cyder-graphics-prepend-patch.sh`  
Expected: `PASS`

- [ ] **Step 5: Rebuild/install Wine ntdll from cyder-wine-engine and smoke loaddll**

In `cyder-wine-engine`, follow `docs/incremental-build-and-patches.md` to rebuild host ntdll with the updated patch, install into the engine tree used by Cyder.

Smoke (isolated prefix with Wine built-in d3d11 only; engine `lib/dxvk` present):

```bash
export WINEPREFIX=... CYDER_GRAPHICS_BACKENDS_ROOT="$ENGINE" CYDER_GRAPHICS_BACKEND=dxvk
export CYDER_COMPATDB_PATH=.../compatdb.cdb WINEDEBUG=+loaddll
arch -x86_64 "$ENGINE/bin/wine" /path/to/load-d3d11.exe
```

Expected: `Loaded ... d3d11.dll ...: builtin` at an address **different** from `CYDER_GRAPHICS_BACKEND=wined3d` on the same prefix.

- [ ] **Step 6: Commit**

```bash
git add patches/cyder-compatdb-runtime.patch patches/cyder-compatdb-runtime-oem25.patch tests/test-cyder-graphics-prepend-patch.sh
git commit -m "$(cat <<'EOF'
fix(compatdb): load DXVK via builtin prepend like DXMT

Align with CrossOver set_graphics_backend: stop preferring native
prefix PE (n,b) so bottles can keep Wine built-in d3d*.

EOF
)"
```

(Also commit the engine-repo patch/rebuild per that repo’s workflow.)

---

### Task 2: Pack graphics payloads (separate from engine archive)

**Files:**
- Create: `scripts/pack-graphics-payloads.sh`
- Modify: `scripts/pack-engine-artifact.sh` in **cyder-wine-engine** (and ogom copy if still used): exclude `lib/dxvk`/`lib/dxmt` from engine tar; remove “refuse without dxvk/dxmt” gates (or invert: refuse if they are still present when packing engine)
- Modify: `tests/test-cyder-pack-dxmt-gate.sh` / engine pack tests to match new gates
- Create: `tests/test-cyder-pack-graphics-payloads.sh`

**Interfaces:**
- Consumes: built engine tree that still has `lib/dxvk` and `lib/dxmt` **before** strip-to-artifact (or dedicated staging dirs from `build-dxvk.sh` / `fetch-dxmt.sh`)
- Produces:
  - `dist/artifacts/graphics/dxvk-<ver>.tar.zst`
  - `dist/artifacts/graphics/dxvk-version.txt`
  - `dist/artifacts/graphics/dxvk-artifact-sha256.txt`
  - same trio for `dxmt`
  - Engine archive **without** `lib/dxvk` / `lib/dxmt`

- [ ] **Step 1: Failing test for graphics pack outputs**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Dry-run or fixture: script must exist and --help lists dxvk/dxmt
bash "$ROOT/scripts/pack-graphics-payloads.sh" --help | grep -q dxvk
```

- [ ] **Step 2: Implement `pack-graphics-payloads.sh`**

Minimal behavior:

```bash
# Pseudo-structure — implement fully in script
# 1) Read version from lib/dxvk (pin file or derived label) and lib/dxmt/version
# 2) tar + zstd each tree from ENGINE/lib/dxvk and ENGINE/lib/dxmt
# 3) write version + sha256 sidecars next to archives under dist/artifacts/graphics/
```

Use bundled `tools/zstd/zstd` like engine pack.

- [ ] **Step 3: Change engine pack to exclude graphics libs**

In cyder-wine-engine `pack-engine-artifact.sh`:

- Add tar `--exclude=lib/dxvk --exclude=lib/dxmt`
- Replace “Refusing to pack without dxvk/dxmt” with: before packing engine, require graphics payloads already produced **or** run `pack-graphics-payloads.sh` first; engine archive itself must not contain those dirs

- [ ] **Step 4: Update gate tests**

`tests/test-cyder-pack-dxmt-gate.sh` should assert graphics pack script / app payload requires DXMT, **not** that the wine engine tarball contains `lib/dxmt`.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(pack): ship DXVK/DXMT as separate graphics payloads

Keep MoltenVK in the engine archive; exclude lib/dxvk and lib/dxmt
from the Wine tarball so graphics can update independently.

EOF
)"
```

---

### Task 3: `cyder_ensure_graphics` — install/update + engine symlinks

**Files:**
- Create: `scripts/cyder-ensure-graphics.sh`
- Modify: `scripts/cyder-common.sh` — add `cyder_ensure_graphics` wrapper sourcing paths
- Create: `tests/test-cyder-ensure-graphics.sh`

**Interfaces:**
- Consumes: env `CYDER_SUPPORT`, `CYDER_RUNTIME_ROOT`, `CYDER_ENGINES`, `CYDER_ENGINE_NAME`, app Resources `graphics/` (or `CYDER_GRAPHICS_SRC`)
- Produces:
  - `cyder_ensure_graphics` → 0 on success
  - `$CYDER_RUNTIME_ROOT/graphics/{dxvk,dxmt}/<ver>/…`
  - `$CYDER_RUNTIME_ROOT/graphics/current-dxvk` / `current-dxmt` (symlink)
  - `$CYDER_ENGINES/$CYDER_ENGINE_NAME/lib/dxvk` → `../../../graphics/current-dxvk` (relative from engine lib)
  - `$CYDER_ENGINES/$CYDER_ENGINE_NAME/lib/dxmt` → likewise

- [ ] **Step 1: Failing test with temp dirs**

```bash
# Arrange: fake Resources/graphics with tiny tar.zst + version/sha
# Act: bash cyder-ensure-graphics.sh
# Assert: current-dxvk exists; engine/lib/dxvk symlink resolves to d3d11.dll
```

- [ ] **Step 2: Implement ensure script**

Logic:

1. Read bundled `dxvk-version.txt` / sha; compare to `$RUNTIME/graphics/current-dxvk/version` (or marker).
2. On mismatch/missing: extract archive to `graphics/dxvk/<ver>/`, atomically update `current-dxvk`.
3. Same for dxmt.
4. `mkdir -p "$ENGINE/lib"`; `ln -sfn` relative links for `lib/dxvk` and `lib/dxmt`.
5. Idempotent when versions match (no re-extract).

- [ ] **Step 3: Pass test**

Run: `bash tests/test-cyder-ensure-graphics.sh`  
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(graphics): ensure DXVK/DXMT payloads into runtime with engine symlinks

EOF
)"
```

---

### Task 4: Migrate old bottles back to Wine built-in d3d*

**Files:**
- Create: `scripts/cyder-migrate-graphics-prefix.sh`
- Modify: `scripts/cyder-common.sh` — call from Cyder open / bootstrap path after ensure-graphics
- Create: `tests/test-cyder-migrate-graphics-prefix.sh`

**Interfaces:**
- Consumes: `WINE_INSTALL`/`engine` path, `WINEPREFIX`/`prefix`
- Produces: `cyder_migrate_graphics_prefix "$wine_bin" "$engine" "$prefix"` → 0; restores built-ins when markers/hashes match

- [ ] **Step 1: Failing test**

```bash
# Copy Wine builtin d3d11 to prefix, then overwrite with fixture "dxvk" bytes
# Write .cyder-runtime/dxvk-payload
# Run migrate
# Assert: d3d11 sha == engine lib/wine/x86_64-windows/d3d11.dll
# Assert: dxvk-payload removed; winemetal.dll removed if present
```

- [ ] **Step 2: Implement migration**

Detect if either:

- `$prefix/.cyder-runtime/dxvk-payload` or `dxmt-payload` exists, or
- `system32/d3d11.dll` sha256 equals `$engine/lib/dxvk/.../d3d11.dll` or `lib/dxmt/...` **when those trees exist via symlink**

If detected, copy from `$engine/lib/wine/x86_64-windows/` and `i386-windows/` the modules: `d3d9`, `d3d10`, `d3d10_1`, `d3d10core`, `d3d11`, `dxgi`. Delete `winemetal.dll` in system32/syswow64 if present. Remove payload markers. Do **not** edit registry DllOverrides.

- [ ] **Step 3: Pass test + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(graphics): migrate bottles off copied DXVK/DXMT prefix PE

EOF
)"
```

---

### Task 5: Wire Cyder open vs Finder EXE

**Files:**
- Modify: `scripts/cyder_launcher.sh` — add `--ensure-graphics-only`; call ensure+migrate from settings/bootstrap paths; document skip
- Modify: `scripts/cyder_app_main.swift` — `ensureEnvironment` / `prepareEnvironmentAndShowSettings` call ensure-graphics; `runPhasedLaunch` (Finder) must **not**
- Modify: `scripts/cyder-common.sh` — remove `install-dxvk-prefix` from `cyder_provision_prefix_baseline`; remove launch-time `install-dxmt-prefix` PE copy block
- Modify: `scripts/create-cyder-app.sh` — copy `Resources/graphics/` artifacts; include new scripts
- Update: `tests/test-cyder-bootstrap.sh` / launcher tests asserting no DXVK copy during bootstrap
- Update: user-facing progress strings if needed (`正在準備圖形元件…`)

**Interfaces:**
- Consumes: Task 3–4 scripts
- Produces: production path behavior matching the spec §2.5 / §2.6

- [ ] **Step 1: Failing tests**

1. Bootstrap fixture: after `--bootstrap-only`, `system32/d3d11.dll` sha == Wine builtin, not dxvk.  
2. Swift/launcher: document-launch / `--launch-exe` path does not invoke ensure-graphics (assert via stub script that creates a sentinel only when ensure-graphics runs; Finder launch must not create sentinel).

- [ ] **Step 2: Remove prefix provision from baseline**

In `cyder_provision_prefix_baseline`, delete the `install-dxvk-prefix.sh` progress block (or gate it behind an explicit migrate-only tool). Remove launch `install-dxmt-prefix.sh` when backend is dxmt.

- [ ] **Step 3: Swift / launcher wiring**

- Settings / cold open: after ensure-engine, run `--ensure-graphics-only` then migrate shared prefix.  
- `runPhasedLaunch`: no ensure-graphics.  
- If backend requested but `engine/lib/dxvk` missing → unavailable → fall back to default; Finder shows alert to open Cyder.app when graphics missing entirely.

- [ ] **Step 4: Bundle graphics in `create-cyder-app.sh`**

Copy `dist/artifacts/graphics/*` into `Contents/Resources/graphics/`. Fail closed if missing when building release.

- [ ] **Step 5: Run focused tests + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(launch): ensure graphics on Cyder open; prepend-only at game start

Stop provisioning DXVK/DXMT into bottles during bootstrap. Finder EXE
launches skip graphics payload upgrades.

EOF
)"
```

---

### Task 6: Docs + verification checklist

**Files:**
- Modify: `docs/cyder-graphics-backends.zh-TW.md` — describe prepend model, Cyder open vs Finder
- Modify: `docs/scripts.md` — new scripts
- Mark: `docs/superpowers/specs/2026-08-10-cyder-graphics-runtime-prepend-design.md` status → 已核准／實作中

- [x] **Step 1: Update user/docs strings to match behavior**

- [x] **Step 2: Manual checklist from spec §3.4**

- [ ] New bottle: no DXVK copy; d3d11 = Wine builtin  
- [ ] Force each backend: bottle d3d11 hash unchanged; loaddll matches prepend model  
- [ ] Old bottle migrates on Cyder open  
- [ ] Cyder open updates graphics; Finder does not  
- [ ] GPTK missing does not block Cyder  
- [ ] Engine tar has no lib/dxvk|dxmt; app has Resources/graphics  

- [x] **Step 3: Commit docs**

```bash
git commit -m "$(cat <<'EOF'
docs(graphics): document runtime prepend graphics payloads

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| DXVK `b`+prepend like CX | Task 1 |
| DXVK/DXMT out of engine tar; app archives | Task 2 |
| ensure on Cyder open; symlinks; MoltenVK via engine root | Task 3 |
| Migrate old PE copies; delete winemetal; no registry wipe | Task 4 |
| Remove bootstrap/launch provision; Finder skip update | Task 5 |
| GPTK soft status | Task 5 (UI status already soft; no new block) |
| Docs + verification | Task 6 |

## Placeholder scan

No TBD/TODO left in task steps; MoltenVK root choice locked to engine symlink view in Task 3.
