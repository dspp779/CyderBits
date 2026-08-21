# wineboot -i/-u selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select `wineboot -i` for new/rebuild prefixes and `wineboot -u` for existing ones; keep shared bottle on engine upgrade.

**Architecture:** Infer flag from `system.reg` inside `cyder_init_bottle`. Engine upgrades only clear `.cyder-bootstrap-v1`. Rebuild deletes the bottle first so init always sees create → `-i`.

**Tech Stack:** Bash (`scripts/cyder-common.sh`), Cyder bootstrap tests, docs under `docs/`.

## Global Constraints

- Existence criterion: `[[ -f "$bottle/system.reg" ]]` (spec).
- Engine upgrade must not delete SharedPrefix contents.
- Log every wineboot with `wineboot_flag` and `wineboot_reason=create|update`.
- Conventional Commits; do not commit `.research/` or large binaries.

---

### Task 1: Finish `cyder_init_bottle` logging + reason

**Files:**
- Modify: `scripts/cyder-common.sh` (`cyder_init_bottle`)
- Test: `tests/test-cyder-wineboot-flag.sh` (new source-contract test)

**Interfaces:**
- Produces: logs contain `wineboot_flag=-i|-u` and `wineboot_reason=create|update`
- Consumes: existing `cyder_init_bottle` / `cyder_run` wineboot invocation

- [ ] **Step 1: Write failing contract test**

Create `tests/test-cyder-wineboot-flag.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" 'wineboot_flag="-i"' "default create flag is -i"
assert_contains "$common" 'wineboot_flag="-u"' "existing prefix uses -u"
assert_contains "$common" 'wineboot "$wineboot_flag"' "wineboot invocation uses flag variable"
assert_contains "$common" 'wineboot_reason=' "logs must record wineboot_reason"
assert_contains "$common" 'cyder_invalidate_shared_bootstrap_for_engine_upgrade' \
  "engine upgrade invalidates bootstrap instead of wiping"
assert_not_contains "$common" 'cyder_reset_shared_prefix'$'\n' \
  "placeholder — instead assert upgrade path does not call reset:"
# Prefer:
assert_contains "$common" 'cyder_invalidate_shared_bootstrap_for_engine_upgrade'
# Ensure upgrade call sites use invalidate, not reset:
upgrade_block="$(awk '/Upgrading shared engine/,/Installing shared engine/' <<<"$common")"
assert_contains "$upgrade_block" "cyder_invalidate_shared_bootstrap_for_engine_upgrade" \
  "version bump must invalidate bootstrap"
assert_not_contains "$upgrade_block" "cyder_reset_shared_prefix" \
  "version bump must not wipe SharedPrefix"
assert_contains "$common" 'cyder_rebuild_shared_prefix' "rebuild helper remains"
rebuild="$(awk '/^cyder_rebuild_shared_prefix/,/^cyder_ensure_shared_prefix/' <<<"$common")"
assert_contains "$rebuild" "cyder_remove_path" "rebuild deletes bottle before provision"
assert_contains "$rebuild" "cyder_provision_prefix_baseline" "rebuild re-provisions after wipe"
echo "PASS test-cyder-wineboot-flag"
```

- [ ] **Step 2: Run test — expect FAIL on missing `wineboot_reason=`**

Run: `bash tests/test-cyder-wineboot-flag.sh`  
Expected: FAIL missing `wineboot_reason=`

- [ ] **Step 3: Add reason to init logging**

In `cyder_init_bottle`, when setting the flag:

```bash
local wineboot_flag="-i"
local wineboot_reason="create"
if [[ -f "$bottle/system.reg" ]]; then
  cyder_seed_crossover_bottle_conf "$wine_bin" "$bottle" || return $?
  echo "Updating bottle: $bottle" >&2
  wineboot_flag="-u"
  wineboot_reason="update"
else
  echo "Creating bottle: $bottle" >&2
  mkdir -p "$bottle"
  cyder_seed_crossover_bottle_conf "$wine_bin" "$bottle" || return $?
fi
```

In the log header block add:

```bash
echo "wineboot_flag=$wineboot_flag"
echo "wineboot_reason=$wineboot_reason"
```

- [ ] **Step 4: Run test — expect PASS**

Run: `bash tests/test-cyder-wineboot-flag.sh`  
Expected: `PASS test-cyder-wineboot-flag`

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder-common.sh tests/test-cyder-wineboot-flag.sh
git commit -m "$(cat <<'EOF'
feat(bootstrap): select wineboot -i/-u by prefix and log reason

New bottles and rebuilds use -i; existing system.reg uses -u. Engine upgrades keep SharedPrefix.
EOF
)"
```

---

### Task 2: Engine-upgrade + docs alignment

**Files:**
- Modify: `tests/test-cyder-engine-tarball.sh` (already partially updated)
- Modify: `docs/cyder.md`, `docs/cyder-graphics-runtime-pipeline.zh-TW.md`
- Modify: `docs/superpowers/specs/2026-08-21-wineboot-i-u-selection-design.md` (status → approved)

**Interfaces:**
- Consumes: `cyder_invalidate_shared_bootstrap_for_engine_upgrade`
- Produces: docs match decision table; tarball test proves bottle kept + marker cleared

- [ ] **Step 1: Confirm tarball test covers keep + clear marker**

Ensure `tests/test-cyder-engine-tarball.sh` asserts:
- upgrade output contains `keeping shared bottle`
- `.cyder-bootstrap-v1` removed
- user marker file under SharedPrefix still exists

- [ ] **Step 2: Run**

Run: `bash tests/test-cyder-engine-tarball.sh`  
Expected: PASS

- [ ] **Step 3: Docs**

`docs/cyder.md` bootstrap step 2 must describe `-i` / `-u` / rebuild.  
Graphics pipeline doc must say upgrade keeps bottle + clears marker, not `cyder_reset_shared_prefix`.  
Spec status line → `approved`.

- [ ] **Step 4: Commit**

```bash
git add tests/test-cyder-engine-tarball.sh docs/cyder.md \
  docs/cyder-graphics-runtime-pipeline.zh-TW.md \
  docs/superpowers/specs/2026-08-21-wineboot-i-u-selection-design.md
git commit -m "$(cat <<'EOF'
docs(bootstrap): document wineboot -i/-u lifecycle and approve spec

EOF
)"
```

---

### Task 3: Spec status + plan checkbox sync

**Files:**
- Modify: this plan checkboxes as tasks complete

- [ ] Mark tasks done after verification; no further code unless Task 1–2 gaps remain.

## Spec coverage

| Spec requirement | Task |
|------------------|------|
| New → `-i` | 1 |
| Existing → `-u` | 1 |
| Rebuild → delete → `-i` | 1 (rebuild contract) |
| Engine upgrade keep bottle | 1–2 |
| Log flag + reason | 1 |
| Docs / tests | 2 |

## Self-review

- No TBD placeholders.
- Rebuild `-i` guaranteed by delete-before-provision (no separate force flag).
