# Design: wineboot `-i` / `-u` selection by prefix lifecycle

**Date:** 2026-08-21  
**Status:** approved — 2026-08-21  
**Related:** `scripts/cyder-common.sh` (`cyder_init_bottle`, `cyder_rebuild_shared_prefix`, engine upgrade invalidate), bench `debug/wineboot-init-bench-multi-20260821-160430/`

## Problem

Cyder previously always used `wineboot -u` for cold create, and on engine version bumps wiped the shared bottle then recreated it. Bench on CX26 (empty prefix, 8 rounds, alternating order) shows:

| mode | mean | median | stdev | min–max |
|------|-----:|-------:|------:|---------|
| `-i` | 12.9 s | 13.5 s | 1.7 s | 10.1–15.3 s |
| `-u` | 19.9 s | 20.1 s | 2.0 s | 16.9–23.1 s |

Despite run-to-run noise (~±2 s), `-i` was faster in every round (~1.5× median). Wine semantics also match Cyder’s lifecycle better if we stop treating every bootstrap as an “update.”

## Goals

1. **New / empty prefix** → `wineboot -i` (first-time init, faster).
2. **Existing prefix** (engine upgrade / re-provision) → `wineboot -u` (update in place; keep user state).
3. **Preferences → 重建 Windows** → delete bottle, then `wineboot -i` (clean slate, same as new).
4. Keep engine upgrades from deleting shared bottle; only invalidate bootstrap so the next open re-provisions with `-u`.
5. Make the chosen flag **observable** in logs / timing for future first-open measurements.

## Non-goals

- Changing Mono/Gecko install order or parallel download pipeline.
- Auto-healing corrupt prefixes beyond “user hits 重建”.
- Per-game profile template revival (still deferred to 1.0.0).
- Forcing `wineboot -u` on every app launch when `.cyder-bootstrap-v1` is already present.

## Approaches considered

| | Approach | Pros | Cons |
|--|----------|------|------|
| **A (recommended)** | Infer flag from **`system.reg` presence** inside `cyder_init_bottle`; rebuild deletes prefix first so init sees “absent” → `-i` | One rule; matches Wine; rebuild needs no extra API | Relies on rebuild delete succeeding before provision |
| B | Pass explicit mode `create\|update\|rebuild` into `cyder_init_bottle` | Clearest call sites | Duplicates knowledge; easy to pass wrong mode |
| C | Env override `CYDER_WINEBOOT_FLAG` only | Good for experiments | Easy to misuse in production paths |

**Recommendation:** **A**, with rebuild’s delete step documented as the hard guarantee for `-i`, and logs recording `wineboot_reason=create|update|rebuild` (rebuild = create after wipe).

## Decision table

| Caller / situation | Prefix on disk before wineboot | Flag | Notes |
|--------------------|--------------------------------|------|--------|
| First open / no bottle | absent (no `system.reg`) | **`-i`** | `mkdir` + seed `cxbottle.conf` then `-i` |
| Engine version change | present (`system.reg`) | **`-u`** | Do **not** delete bottle; clear `.cyder-bootstrap-v1` only |
| Same-label artifact refresh | present | **(no wineboot)** | Engine refresh only; marker kept if SHA/version match path leaves bottle alone |
| Marker missing, bottle intact | present | **`-u`** | Re-provision / repair path |
| 重建 Windows | deleted, then absent | **`-i`** | `cyder_rebuild_shared_prefix` removes bottle, then `cyder_provision_prefix_baseline` → init |
| Profile / staging new bottle | absent | **`-i`** | Same helper |
| Partial dir without `system.reg` | treat as **absent** | **`-i`** | Avoid `-u` on broken half-inits |

### Existence criterion

**Canonical check:** `[[ -f "$bottle/system.reg" ]]`.

Rationale: Cyder already treats `system.reg` as “bottle usable enough to skip create” elsewhere; directory alone can be an empty shell with only `cxbottle.conf`.

## Detailed flows

### 1. First create

```
cyder_provision_prefix_baseline
  → cyder_init_bottle
       no system.reg
       → mkdir, seed cxbottle.conf
       → wineboot -i
       → wait artifacts (drive_c + kernel32)
       → dosdevices c:/z:
  → mono/gecko/… (unchanged)
  → write .cyder-bootstrap-v1
```

### 2. Engine upgrade (in-place)

```
cyder_ensure_shared_engine (version label changed)
  → cyder_invalidate_shared_bootstrap_for_engine_upgrade
       rm .cyder-bootstrap-v1
       drop templates/ if present
  → install new engine tree (no SharedPrefix delete)

Later open / bootstrap:
  → cyder_provision_prefix_baseline (marker missing)
  → cyder_init_bottle
       system.reg present → wineboot -u
  → mono/gecko skip if version markers match; else reinstall
  → rewrite .cyder-bootstrap-v1
```

User Winetricks / registry customizations remain unless they conflict with the new engine; salvage path is 重建.

### 3. Rebuild (Preferences)

```
cyder_rebuild_shared_prefix
  → refuse if Wine running / symlink bottle
  → wineserver -k for prefix
  → cyder_remove_path(SharedPrefix)   # hard wipe
  → cyder_provision_prefix_baseline
       → cyder_init_bottle → no system.reg → wineboot -i
  → write .cyder-bootstrap-v1
```

If delete fails, abort before provision (existing behavior). Do **not** call `wineboot -u` on a half-deleted tree.

### 4. Logging

Each wineboot operation log (`Logs/operations/wineboot-*.log`) must include:

- `wineboot_flag=-i|-u`
- `wineboot_reason=create|update`  
  - `create` when flag is `-i` (includes rebuild after wipe)  
  - `update` when flag is `-u`
- existing fields: wine, prefix, engine_version, duration_ms, exit_status

Optional stderr line: `Creating bottle` / `Updating bottle` (already useful for support).

## Edge cases

| Case | Behavior |
|------|----------|
| `system.reg` exists but `drive_c`/kernel32 missing | Still `-u`; artifact wait / failure codes unchanged; user may 重建 |
| wineboot timeout / non-zero | Keep wineserver kill cleanup; leave marker unset so retry re-enters provision |
| Concurrent rebuild + game | Already blocked by `cyder_has_running_prefix` |
| Profile bottles | Same `cyder_init_bottle` rules; no special rebuild UI unless added later |
| `cyder_reset_shared_prefix` | Retained only if still needed as a low-level wipe helper; **not** called on engine upgrade |

## Tests

1. **Unit/contract (string / fixture):**  
   - Engine version bump keeps SharedPrefix contents; clears `.cyder-bootstrap-v1`; log/message mentions keeping bottle.  
   - `cyder_init_bottle` path: absent `system.reg` → invokes `wineboot -i`; present → `wineboot -u` (assert on script source or a small harness that mocks `cyder_run`).
2. **Rebuild contract:** after wipe, provision path uses `-i` (source assert: rebuild deletes then calls provision; init selects `-i` when no `system.reg`).
3. **Docs:** `docs/cyder.md` bootstrap steps match the table; graphics pipeline note about engine upgrade no longer claims full prefix wipe.

## Implementation notes (for plan phase)

Working tree may already contain a partial A implementation (`wineboot_flag` + invalidate-on-upgrade). Plan should:

1. Align code with this spec (reason logging, tests, docs).
2. Confirm rebuild → delete → `-i` with an explicit test.
3. Avoid behavior change to Mono/Gecko skip markers unless required for upgrade re-provision.
4. Commit design first; then implementation commits (Conventional Commits).

## Success criteria

- Empty-prefix path uses `-i`; existing-`system.reg` path uses `-u`; rebuild ends in `-i`.
- Engine upgrade does not delete SharedPrefix user data.
- wineboot logs always record flag (+ reason).
- Existing bootstrap timing / MSI parallel pipeline still passes.

## Open question (resolve on approval)

None blocking — existence criterion is `system.reg` as above. If you prefer “directory empty of drive_c” instead, say so before implementation.
