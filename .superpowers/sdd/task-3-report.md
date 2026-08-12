# Task 3 Report: Ensure-graphics and shell launch preference

## Summary

Installed `current-dxvk2` + `$engine/lib/dxvk2` via `cyder_ensure_graphics`, and extended `cyder_apply_graphics_preference` to accept `dxvk2` with fail-closed behavior when `lib/dxvk2` is missing.

## TDD Evidence

### RED (Step 2 — tests fail before implementation)

```bash
$ bash tests/test-cyder-ensure-graphics.sh
ASSERT failed: test -f .../runtime/graphics/dxvk2/2.7.1/d3d11.dll
# exit 1

$ bash tests/test-cyder-settings-model.sh
ASSERT_CONTAINS failed: shell preference helper must handle dxvk2
  missing: dxvk2)
# exit 1
```

### GREEN (Step 4 — both pass after implementation)

```bash
$ bash tests/test-cyder-ensure-graphics.sh
PASS test-cyder-ensure-graphics

$ bash tests/test-cyder-settings-model.sh
PASS test-cyder-settings-model
```

## Files Changed

| File | Change |
|------|--------|
| `scripts/cyder-ensure-graphics.sh` | Install dxvk2 payload; symlink `engine/lib/dxvk2` → `current-dxvk2` |
| `scripts/cyder-common.sh` | Add `cyder_engine_has_dxvk2_payload`; `dxvk2)` branch in `cyder_apply_graphics_preference` |
| `tests/test-cyder-ensure-graphics.sh` | dxvk2 staging, install/symlink asserts, 1.x upgrade must not touch 2.x |
| `tests/test-cyder-settings-model.sh` | Assert dxvk2 preference helper and fail-closed helper present |

## Behavior

- `cyder_ensure_graphics` now installs dxvk, dxvk2, and dxmt payloads and links all three under `engine/lib/`.
- `cyder_apply_graphics_preference dxvk2` exports `CYDER_GRAPHICS_BACKEND=dxvk2` when `lib/dxvk2/x86_64-windows/d3d11.dll` exists; otherwise falls back to default with stderr warning.
- DXVK 1.x version upgrades do not alter `current-dxvk2`.

## Out of Scope (per brief)

- Swift UI / schema changes
- Unrelated dirty ogom files not staged
