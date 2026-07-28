# Cyder DXVK HUD And OEM Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global DXVK frametimes toggle, hide GPTK-only controls when non-GPTK backends are selected, and give the OEM app a distinct bundle executable.

**Architecture:** Extend the graphics settings model with one new global boolean, thread it through launch-environment generation, then update both graphics UIs to reflect backend-dependent control visibility. Finally, adjust OEM packaging so its bundle executable and signed launcher filename diverge from the official app without changing official packaging.

**Tech Stack:** Swift AppKit UI, Swift settings model, bash packaging scripts, shell-based regression tests

## Global Constraints

- Keep the existing `顯示畫面流暢度` control as the main HUD selector.
- Add a separate global checkbox for DXVK frametimes instead of expanding the HUD mode enum.
- Do not add a per-game frametimes override.
- Hide GPTK installation/status controls when the selected backend is `dxvk` or `wined3d`.
- Keep GPTK controls visible for `d3dmetal`, `auto`, and official-build `default`.
- Give the OEM bundle a distinct `CFBundleExecutable` and matching `Contents/MacOS` launcher filename.
- Do not change the official bundle executable name.
- Do not preserve compatibility with older `settings.json` schema versions.

---

### Task 1: Extend Graphics Settings Model

**Files:**
- Modify: `scripts/cyder_settings.swift`
- Test: `tests/test-cyder-settings-swift.sh`
- Test: `tests/fixtures/cyder_settings_harness.swift`

**Interfaces:**
- Consumes: existing `CyderSettings`, `CyderGraphicsHud`, `CyderSettingsStore.environment()`
- Produces: `CyderSettings.dxvkHudFrametimes: Bool`, updated HUD env generation, updated schema version

- [ ] **Step 1: Write the failing test**

Add harness assertions that a DXVK HUD with frametimes disabled emits `DXVK_HUD=fps`, and enabled emits `DXVK_HUD=fps,frametimes`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-settings-swift.sh`
Expected: FAIL because the new setting and HUD mapping do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Update `scripts/cyder_settings.swift` to:
- add `dxvkHudFrametimes`
- bump the current schema version
- decode/encode the new setting as the current format
- emit `DXVK_HUD=fps` or `fps,frametimes` when `graphicsHud == .dxvk`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-cyder-settings-swift.sh`
Expected: PASS

### Task 2: Update Graphics UI Visibility Rules

**Files:**
- Modify: `scripts/cyder_settings_ui.swift`
- Modify: `scripts/cyder_game_library_ui.swift`
- Test: `tests/test-cyder-force-settings-ui.sh`

**Interfaces:**
- Consumes: `CyderSettings.dxvkHudFrametimes`, existing backend selectors
- Produces: frametimes checkbox in global settings, backend-specific GPTK/DXVK control visibility

- [ ] **Step 1: Write the failing test**

Add source assertions covering:
- new frametimes checkbox
- GPTK controls hidden for `dxvk` and `wined3d`
- GPTK controls visible for `d3dmetal`, `auto`, and official `default`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-force-settings-ui.sh`
Expected: FAIL because the new UI and visibility helpers are missing.

- [ ] **Step 3: Write minimal implementation**

Update:
- global settings window to add the frametimes checkbox
- global refresh logic to show/hide DXVK-only controls and GPTK-only controls by backend
- per-game settings window to keep no frametimes override while matching GPTK visibility rules

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-cyder-force-settings-ui.sh`
Expected: PASS

### Task 3: Rename OEM Bundle Executable

**Files:**
- Modify: `scripts/create-cyder-maplestory-oem-app.sh`
- Test: `tests/test-cyder-app-payload.sh`

**Interfaces:**
- Consumes: OEM app packaging flow from `create-cyder-maplestory-oem-app.sh`
- Produces: OEM `CFBundleExecutable=CyderMapleStoryOEM`, packaged launcher at `Contents/MacOS/CyderMapleStoryOEM`

- [ ] **Step 1: Write the failing test**

Add payload assertions that the OEM app packaging script sets `CFBundleExecutable` to `CyderMapleStoryOEM` and signs the renamed launcher path.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-cyder-app-payload.sh`
Expected: FAIL because OEM packaging still uses `Cyder`.

- [ ] **Step 3: Write minimal implementation**

Update the OEM packaging script to:
- rename the OEM launcher file
- set `CFBundleExecutable`
- update the helper-signing loop to include the renamed launcher

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-cyder-app-payload.sh`
Expected: PASS

### Task 4: Focused Verification

**Files:**
- Modify: none
- Test: `tests/test-cyder-settings-swift.sh`
- Test: `tests/test-cyder-force-settings-ui.sh`
- Test: `tests/test-cyder-app-payload.sh`

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified implementation evidence

- [ ] **Step 1: Run focused verification suite**

Run: `bash tests/test-cyder-settings-swift.sh && bash tests/test-cyder-force-settings-ui.sh && bash tests/test-cyder-app-payload.sh`

- [ ] **Step 2: Confirm expected result**

Expected: all three tests pass with no new failures.
