# Task 2 Report: Pack dxvk2 payload and exclude from engine tar

## Summary

Added `lib/dxvk2` to the graphics payload pipeline alongside existing `lib/dxvk` and `lib/dxmt`. Engine tarball now excludes `lib/dxvk2`. Cyder.app packaging requires dxvk2 sidecars.

## TDD Evidence

### RED (Step 2 — tests fail before implementation)

```bash
$ bash tests/test-cyder-pack-graphics-payloads.sh
ASSERT_CONTAINS failed: graphics pack help must list DXVK2
  missing: dxvk2
# exit 1

$ bash tests/test-cyder-pack-dxmt-gate.sh
ASSERT_CONTAINS failed: engine archive must exclude DXVK2
  missing: --exclude 'lib/dxvk2'
# exit 1

$ bash tests/test-cyder-app-payload.sh
ASSERT_CONTAINS failed: Cyder.app packaging must require the DXVK 2 graphics sidecar
  missing: dxvk2-version.txt
# exit 1
```

### GREEN (Step 4 — all three pass after implementation)

```bash
$ bash tests/test-cyder-pack-graphics-payloads.sh
Stamped 1 of 1 DLL(s)
Created graphics artifact: .../dxvk-1.2.3.tar.zst
Stamped 1 of 1 DLL(s)
Created graphics artifact: .../dxvk2-2.7.1.tar.zst
Created graphics artifact: .../dxmt-4.5.6.tar.zst
PASS test-cyder-pack-graphics-payloads

$ bash tests/test-cyder-pack-dxmt-gate.sh
...
Created graphics artifact: .../dxvk2-2.7.1.tar.zst
PASS test-cyder-pack-dxmt-gate

$ bash tests/test-cyder-app-payload.sh
PASS test-cyder-app-payload
```

## Files Changed

### ogom

| File | Change |
|------|--------|
| `scripts/pack-graphics-payloads.sh` | Help lists dxvk2; gate on `lib/dxvk2`; stamp both DXVK families; `pack_payload dxvk2` |
| `scripts/pack-engine-artifact.sh` | `--exclude 'lib/dxvk2'` |
| `scripts/create-cyder-app.sh` | Require dxvk2 version/sha/archive sidecars; updated error message |
| `tests/test-cyder-pack-graphics-payloads.sh` | dxvk2 fake tree + artifact asserts |
| `tests/test-cyder-pack-dxmt-gate.sh` | exclude assert + dxvk2 integration |
| `tests/test-cyder-app-payload.sh` | `dxvk2-version.txt` gate assert |

### cyder-wine-engine (feat/cyder-dxvk2-graphics-backend)

| File | Change |
|------|--------|
| `scripts/pack-engine-artifact.sh` | `--exclude 'lib/dxvk2'` (mirror ogom) |

## Test Note

Brief stamp assert used `name == dxvk || name == dxvk2` but implementation uses quoted `"$name"`. Test updated to assert `'"$name" == dxvk || "$name" == dxvk2'` to match actual bash syntax.

## Out of Scope (per brief)

- ensure-graphics / UI (Task 3+)
- Unrelated dirty ogom files not staged
