# Task 5 Report: Settings and game-library menus

## Summary

Replaced temporary `case .dxvk2: return 0` UI stubs with real DXVK 2 menu entries (after DXVK), payload grey-out via `hasDxvk2`, and limiter/HUD gating through `usesDxvkTranslation` for both DXVK families.

## TDD Evidence

### RED (Step 2 — tests fail before implementation)

```bash
$ bash tests/test-cyder-force-settings-ui.sh
ASSERT_CONTAINS failed: prefs graphics labels include DXVK 2 after DXVK
  missing: return ["預設", "D3DMetal", "DXMT", "DXVK", "DXVK 2", "WineD3D"]
# exit 1
```

### GREEN (Step 4 — UI + settings tests pass after implementation)

```bash
$ bash tests/test-cyder-force-settings-ui.sh
PASS test-cyder-force-settings-ui

$ bash tests/test-cyder-settings-swift.sh
PASS cyder-settings-harness
PASS test-cyder-settings-swift

$ bash tests/test-cyder-settings-model.sh
PASS test-cyder-settings-model
```

## Files Changed

| File | Change |
|------|--------|
| `tests/test-cyder-force-settings-ui.sh` | Assert DXVK 2 titles, `usesDxvkTranslation` limiter/HUD, GPTK hide for `.dxvk2`, tooltip + help strings |
| `scripts/cyder_settings_ui.swift` | Titles + index map 0…5; `canSelectDxvk2` / `updateDxvk2MenuItemAvailability`; HUD/limiter/GPTK via `usesDxvkTranslation` |
| `scripts/cyder_game_library_ui.swift` | Titles + index map 0…6; grey-out DXVK 2 at item 5; override/index for `.dxvk2` |

## Behavior

- Prefs menu: `預設`, `D3DMetal`, `DXMT`, `DXVK`, `DXVK 2`, `WineD3D` (index 4 = dxvk2, 5 = wined3d).
- Game options: `跟隨全域` … `DXVK`, `DXVK 2`, `WineD3D` (index 5 = dxvk2, 6 = wined3d).
- Missing payload: DXVK 2 disabled with tooltip `需要已安裝的 DXVK 2 圖形元件`; selection falls back like DXMT.
- Frame-rate limiter + frametimes visibility for both `.dxvk` and `.dxvk2`; GPTK controls also hide for `.dxvk2`.
- Leaving both DXVK families drops HUD `.dxvk` via `!usesDxvkTranslation`.

## Out of Scope (per brief)

- Pack / ensure / CompatDB
- Unrelated dirty ogom files not staged

## Commit

```
feat(ui): add DXVK 2 graphics translation option
```
