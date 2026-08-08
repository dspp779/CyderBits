# Preferences Apply While Wine Running — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Wine is running, preferences use draft +「套用設定」(live `reg add` then `settings.json`); remove advanced「套用所有設定」.

**Architecture:** UI detects running prefix via `hasRunningExes`. Idle keeps immediate JSON + fast apply. Running defers persistence; Apply passes draft env (`CYDER_RETINA_MODE` etc.) with `CYDER_FORCE_SETTINGS=1` so `cyder-apply-settings.sh` talks to live wineserver, then `saveControls()` writes JSON only on success.

**Tech Stack:** AppKit settings UI, existing launcher `--apply-settings-only`, bash `cyder-apply-settings.sh`.

**Spec:** `docs/superpowers/specs/2026-08-08-cyder-settings-apply-while-wine-running-design.md`

## Global Constraints

- Apply while running: live Wine registry first, then `settings.json` on success only.
- Do not auto-quit games on Apply.
- Idle path unchanged (immediate save).
- Remove advanced「套用所有設定」; keep rebuild / Winetricks.
- Prefer Conventional Commits; do not push; skip commits unless user asks.

## File map

| File | Responsibility |
|------|----------------|
| `scripts/cyder_settings_ui.swift` | Draft mode, Apply button, alert, status, remove apply-all |
| `scripts/cyder_app_main.swift` | Wire Apply → force apply with draft env; drop onApplyAll |
| `tests/test-cyder-force-settings-ui.sh` | Assert new UX contracts |

---

### Task 1: Failing UI contract tests

**Files:** `tests/test-cyder-force-settings-ui.sh`

- [ ] Replace assertions for「套用所有設定」/ `applyAllSettings` / `onApplyAll` with「套用設定」、`applyRunningSettings` / `onApplyWhileRunning` (or chosen names), running status copy, and draft-vs-immediate save branching (`wineIsRunning` / `markDraft` style).
- [ ] Run `bash tests/test-cyder-force-settings-ui.sh` — expect FAIL.

### Task 2: Settings UI draft + Apply chrome

**Files:** `scripts/cyder_settings_ui.swift`

- [ ] Footer:「套用設定」button (visible when running); status strings per spec.
- [ ] `prepareForDisplay`: if running, alert once + `refreshRunningChrome()`.
- [ ] Idle: `saveImmediately` as today. Running: mark dirty / draft only (no `saveControls`).
- [ ] Apply: call `onApplyWhileRunning?(draftEnv)`; on true `saveControls()` + success status; on false error status (no JSON write).
- [ ] Remove advanced apply-all button, note, `applyAllSettings`, `onApplyAll`.
- [ ] Run UI contract test — expect PASS for UI strings.

### Task 3: App delegate wiring

**Files:** `scripts/cyder_app_main.swift`

- [ ] Replace `onApplyAll` with `onApplyWhileRunning` that runs `--apply-settings-only` + `CYDER_FORCE_SETTINGS=1` + draft env keys already kept by `cyder_load_saved_settings`.
- [ ] Remove or leave unused `prepareEnvironmentAfterSettings` if nothing calls it (delete if dead).
- [ ] Run `bash tests/test-cyder-force-settings-ui.sh` — PASS.

### Task 4: Ready to commit

- [ ] Summarize changed files; wait for user commit request (do not commit unless asked).
