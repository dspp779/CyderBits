# Task 2 Report: Settings model — add `dxmt`, remove `auto`

## Status
Done.

## Files changed
- `scripts/cyder_settings.swift`
- `tests/fixtures/cyder_settings_harness.swift`

## Summary of changes

- `CyderGraphicsBackend` is now `default | wined3d | dxvk | dxmt | d3dmetal` — `auto` case removed.
- `CyderProduct.defaultGraphicsBackend` is always `.default` (no more OEM → `.auto`).
- `sanitizedGraphicsBackend(_:)` / `sanitizedOptionalGraphicsBackend(_:)` migrate the legacy raw string `"auto"` → `.default` (so old persisted settings.json / profile JSON still decode cleanly).
- `CyderGraphicsCapabilities` gained `hasDxmt: Bool` and `hasDxmtPayload(engineRoot:)`, mirroring `hasDxvkPayload`'s root resolution (checks `CYDER_GRAPHICS_BACKENDS_ROOT` env, defaults to `true` when no root context) and requiring both `lib/dxmt/x86_64-windows/d3d11.dll` and `lib/dxmt/x86_64-unix/winemetal.so`.
- `CyderGraphicsCapabilities.current(engineRoot:)` now also probes `hasDxmt`.
- `cascadePreferredBackend` removed entirely.
- `effectiveLaunchBackend` no longer cascades: `.default` → `nil` unconditionally (no OEM special case); all concrete backends including `.dxmt` → themselves. Signature now takes `hasDxmt:` (kept for interface symmetry/future use even though the switch no longer branches on capabilities).
- `resolveGraphics` no longer rewrites OEM `.default` → `.auto`.
- `CyderSettingsStore.environment(...)` passes `hasDxmt` through to `effectiveLaunchBackend`, and the DXVK frame-rate-limiter exposure condition was simplified to just `graphics.backend == .dxvk` (the old OEM/cascade branch is unreachable now that `.default` never resolves to a concrete backend).

## Tests (TDD)

1. Updated `tests/fixtures/cyder_settings_harness.swift` first (deleted all `.auto` / `cascadePreferredBackend` assertions, added `hasDxmt` everywhere `CyderGraphicsCapabilities`/`effectiveLaunchBackend` are called, added `hasDxmtPayload` filesystem-based coverage, replaced the OEM block with the brief's verbatim snippet, added `sanitizedGraphicsBackend("auto") == .default` and `sanitizedOptionalGraphicsBackend("auto") == .default` checks).
2. Ran `tests/test-cyder-settings-swift.sh` against the unmodified model → confirmed compile failures (`extra argument 'hasDxmt'`, `type 'CyderGraphicsBackend' has no member 'dxmt'`, `has no member 'hasDxmtPayload'`, etc.) — harness fails as expected before implementation.
3. Implemented the model changes above.
4. Re-ran `tests/test-cyder-settings-swift.sh` → `PASS cyder-settings-harness` / `PASS test-cyder-settings-swift`.
5. Also ran `tests/test-cyder-settings-model.sh` (grep-based assertions on `cyder_settings.swift` / `cyder-common.sh`, untouched by this task) → `PASS test-cyder-settings-model`.

## Commits
- `feat(settings): add dxmt backend and drop auto cascade`

## Concerns / notes for other tasks

- **Task 3 (UI) will not compile until it lands.** `scripts/cyder_settings_ui.swift` and `scripts/cyder_game_library_ui.swift` both reference `.auto` (as a `CyderGraphicsBackend` case) and `cyder_game_library_ui.swift`'s test companion `tests/test-cyder-force-settings-ui.sh` asserts `cascadePreferredBackend` exists. Per the task split these are explicitly out of scope here; confirmed via repo-wide grep that no other Swift file constructs `CyderGraphicsCapabilities` or calls the backend APIs besides those two UI files and this task's own files.
- `tests/test-cyder-force-settings-ui.sh` will fail until Task 3 updates the UI files — did not touch it (out of scope, owned by Task 3).
- `cyder-common.sh` was not touched (owned by Task 4); it doesn't reference the Swift `CyderGraphicsBackend` enum directly (shell side reads `CYDER_GRAPHICS_BACKEND` env string), so no cross-task breakage expected there.
- `effectiveLaunchBackend`'s `hasD3DMetal`/`hasDxvk`/`hasDxmt` parameters are currently unused inside the switch body (no cascade consults them anymore) but were kept per the interface spec in the brief for call-site/API symmetry with `CyderGraphicsCapabilities`.
