# Cyder DXVK HUD And OEM Bundle Design

**Goal:** Refine graphics settings so DXVK HUD can toggle frametimes globally, hide GPTK-only controls when a non-GPTK backend is selected, and give the OEM app a distinct executable name inside the bundle.

## Scope

This design covers three related changes:

1. Add a global-only DXVK frametimes toggle alongside the existing DXVK HUD setting.
2. Hide GPTK-related controls whenever the selected graphics backend cannot use GPTK.
3. Rename the OEM bundle executable so the official app and OEM app no longer both run as `Cyder`.

This design does not include backward compatibility for older `settings.json` schema versions. The settings format may change directly.

## Requirements

- Keep the existing `顯示畫面流暢度` control as the main HUD selector.
- Add a separate global checkbox for DXVK frametimes instead of expanding the HUD mode enum.
- Do not add a per-game frametimes override.
- Hide GPTK installation/status controls when the selected backend is `dxvk` or `wined3d`.
- Keep GPTK controls visible for `d3dmetal`, `auto`, and official-build `default`.
- Give the OEM bundle a distinct `CFBundleExecutable` and matching `Contents/MacOS` launcher filename.
- Do not change the official bundle executable name.

## Design

### 1. Global DXVK frametimes toggle

The existing `CyderGraphicsHud` enum remains the top-level HUD mode selector:

- `off`
- `metal`
- `dxvk`

Add a new global boolean setting:

- `dxvkHudFrametimes: Bool`

When `graphicsHud == .dxvk`, launch environment generation maps the new flag to:

- `DXVK_HUD=fps` when `dxvkHudFrametimes == false`
- `DXVK_HUD=fps,frametimes` when `dxvkHudFrametimes == true`

When `graphicsHud != .dxvk`, the new flag has no runtime effect.

Because compatibility is intentionally not preserved, the settings schema can move directly to a new current version and require the new field during decode/encode.

### 2. Graphics settings UI rules

The global settings window keeps the existing `顯示畫面流暢度` popup and adds:

- `顯示 frametimes` checkbox

Visibility rules:

- Backend `dxvk`: show `限制幀率`, show `顯示畫面流暢度`, show `顯示 frametimes`, hide GPTK controls
- Backend `wined3d`: hide DXVK-only controls, hide GPTK controls
- Backend `d3dmetal`: hide DXVK-only controls, show GPTK controls
- Backend `auto`: hide DXVK-only controls, show GPTK controls
- Backend `default`: official build shows GPTK controls because CompatDB/default may still resolve to a GPTK-backed path; OEM maps `default` to `auto` semantics already

GPTK controls include:

- GPTK status text
- install GPTK button
- remove installed GPTK button
- GPTK explanatory note

The per-game settings window keeps its current scope:

- backend override
- DXVK frame-rate override
- no HUD override
- no frametimes override

This keeps frametimes as a simple global rendering-observability preference.

### 3. OEM bundle executable identity

Today both bundles use `CFBundleExecutable=Cyder`, although Launch Services identity is primarily determined by `CFBundleIdentifier`.

This usually works, but keeping the same executable basename makes process inspection and crash/automation diagnostics ambiguous because both apps appear as `Cyder`.

Change only the OEM bundle:

- `CFBundleExecutable` -> `CyderMapleStoryOEM`
- `Contents/MacOS/Cyder` -> `Contents/MacOS/CyderMapleStoryOEM`

Keep:

- official app `CFBundleExecutable=Cyder`
- OEM helper `CyderOEMBootstrap`

The OEM launcher script contents stay the same; only the filename and packaging/signing references change.

## Files Expected To Change

- `scripts/cyder_settings.swift`
- `scripts/cyder_settings_ui.swift`
- `scripts/cyder_game_library_ui.swift`
- `scripts/create-cyder-maplestory-oem-app.sh`
- `tests/test-cyder-settings-swift.sh`
- `tests/test-cyder-force-settings-ui.sh`
- packaging or payload tests that assert OEM bundle layout

## Risks

- Direct schema bump without compatibility means existing users may need settings regeneration or migration handling elsewhere.
- UI visibility rules must stay consistent between the global settings window and per-game settings window.
- Renaming the OEM executable requires packaging and codesign logic to update every filename reference.

## Testing

- Settings decode/encode tests for the new schema and `dxvkHudFrametimes`
- UI/source assertions for the new frametimes checkbox and GPTK visibility rules
- Packaging test that asserts OEM `CFBundleExecutable` and signed launcher path use the new executable name
- Focused OEM app packaging smoke test after implementation
