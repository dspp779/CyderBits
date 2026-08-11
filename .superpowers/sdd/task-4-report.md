# Task 4 Report: Settings schema 9 and launch environment

## Summary

Added Swift `CyderGraphicsBackend.dxvk2`, schema 9, `hasDxvk2` / `hasDxvk2Payload`, fail-closed `effectiveLaunchBackend`, and shared limiter/HUD via `usesDxvkTranslation`. AppKit menus left for Task 5.

## TDD Evidence

### RED (Step 2 — tests fail before implementation)

```bash
$ bash tests/test-cyder-settings-model.sh
ASSERT_CONTAINS failed: schema version 9
  missing: schemaVersion = 9
# exit 1

$ bash tests/test-cyder-settings-swift.sh
# compile FAIL: CyderGraphicsBackend has no member 'dxvk2';
# compile FAIL: extra argument 'hasDxvk2' in call
# compile FAIL: CyderGraphicsCapabilities has no member 'hasDxvk2Payload'
# exit 1
```

### GREEN (Step 4 — settings tests pass after implementation)

```bash
$ bash tests/test-cyder-settings-model.sh
PASS test-cyder-settings-model

$ bash tests/test-cyder-settings-swift.sh
PASS cyder-settings-harness
PASS test-cyder-settings-swift
```

Also verified:

```bash
$ bash tests/test-cyder-game-launch-settings.sh
PASS test-cyder-game-launch-settings

$ bash tests/test-cyder-force-settings-ui.sh
PASS test-cyder-force-settings-ui
```

`test-cyder-force-settings-ui.sh` currently has no DXVK 2 menu-title asserts (Task 5 will add them), so it stayed green; asserts were not weakened.

## Files Changed

| File | Change |
|------|--------|
| `scripts/cyder_settings.swift` | `dxvk2` enum + `usesDxvkTranslation`; schema 9; `hasDxvk2` / `hasDxvk2Payload`; fail-closed launch; shared frame-rate/HUD |
| `scripts/cyder_app_main.swift` | `graphicsPayloadsPresent()` also accepts `lib/dxvk2/.../d3d11.dll` |
| `tests/fixtures/cyder_settings_harness.swift` | schema 9, dxvk2 env/HUD/fail-closed, `hasDxvk2Payload` probe, updated call sites |
| `tests/test-cyder-settings-model.sh` | schema 9 + enum / `usesDxvkTranslation` string asserts |

## Behavior

- Settings encode/decode/update at schema 9; `sanitizedGraphicsBackend("dxvk2")` → `.dxvk2`.
- `effectiveLaunchBackend(.dxvk2)` returns `.dxvk2` only when `hasDxvk2`; otherwise `nil`.
- `environment()` sets `CYDER_GRAPHICS_BACKEND=dxvk2`, `DXVK_FRAME_RATE=60`, and DXVK HUD for dxvk2 the same way as dxvk, gated by `usesDxvkTranslation`.
- `resolvedGraphicsHud` allows DXVK HUD for both `.dxvk` and `.dxvk2`.

## Out of Scope (per brief)

- AppKit menus / Task 5 UI string asserts
- Unrelated dirty ogom files not staged

## Review fix: dxvk2 UI switch stubs

Minimal `case .dxvk2:` stubs so exhaustive switches typecheck after schema 9
(menus remapped in Task 5).

- `scripts/cyder_settings_ui.swift` — `graphicsBackendIndex` → `0`; `graphicsHelp` one-liner
- `scripts/cyder_game_library_ui.swift` — `graphicsBackendIndex` → `0`

### Verification

```bash
$ bash tests/test-cyder-settings-swift.sh
PASS cyder-settings-harness
PASS test-cyder-settings-swift

$ bash tests/test-cyder-settings-model.sh
PASS test-cyder-settings-model

$ swiftc -typecheck -sdk "$SWIFT_SDK" -module-cache-path "$SWIFT_MODULE_CACHE" \
    -target arm64-apple-macosx11.0 \
    scripts/cyder_diagnostics.swift \
    scripts/cyder_paths.swift \
    scripts/cyder_gptk.swift \
    scripts/cyder_settings.swift \
    scripts/cyder_launch_support.swift \
    scripts/cyder_status_item.swift \
    scripts/cyder_profiles.swift \
    scripts/cyder_settings_ui.swift \
    scripts/cyder_game_library.swift \
    scripts/cyder_bottle_shortcuts.swift \
    scripts/cyder_game_icon.swift \
    scripts/cyder_game_library_ui.swift \
    scripts/cyder_app_main.swift
# (no diagnostics)
EXIT:0
```
