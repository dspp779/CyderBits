# Task 3 Report: Gate `ensureEnvironment` with consent UI

**Branch:** `feat/rosetta-consent-install`  
**Date:** 2026-08-25

## Summary

Wired `ensureRosettaForEnvironment()` at the top of `ensureEnvironment` in `cyder_app_main.swift`. Apple Silicon machines missing Rosetta now see an NSAlert consent dialog, then `CyderSetupPanel` during `--agree-to-license` install via `CyderRosetta.installWithAgreedLicense()`. Cancel or install failure returns `CYD-ROS-001` with stage `.rosettaCheck`.

## TDD cycle

| Step | Result |
|------|--------|
| Append Task 3 contract asserts | Done — 4 checks before final `PASS` |
| RED | `ASSERT_CONTAINS failed: app must surface CYD-ROS-001` |
| Implement | `ensureRosettaForEnvironment` + gate in `ensureEnvironment` |
| GREEN | `PASS test-cyder-rosetta` (exit 0) |

## Files changed

| File | Change |
|------|--------|
| `scripts/cyder_app_main.swift` | **New** `ensureRosettaForEnvironment()`; called first in `ensureEnvironment` |
| `tests/test-cyder-rosetta.sh` | Task 3 app contract asserts (4 checks) |

## Interfaces delivered

```swift
private func ensureRosettaForEnvironment() -> CyderFailure?
// Called at start of ensureEnvironment(context:) before needsEngine
```

- Consent title: `需要安裝 Rosetta 2`
- Copy covers: Apple official component, x86_64 need, license acceptance on user's behalf
- Error: `CYD-ROS-001`, stage `.rosettaCheck`
- Install runs off main thread when `ensureEnvironment` is invoked from background queue; alert wrapped in `onMainThread` (matches `showSetup` / `showAlert` patterns)

## Contract asserts (Task 3)

- App surfaces `CYD-ROS-001`
- App shows consent title `需要安裝 Rosetta 2`
- `ensureEnvironment` references `ensureRosettaForEnvironment`
- App calls `installWithAgreedLicense` (consent path only)

Task 1/2 asserts preserved; SKIP-safe runtime block unchanged.

## Commit

```
2348fd4 feat(app): consent and install Rosetta before engine ensure
```

## Self-review

**Strengths**
- Gate runs before engine/graphics/bootstrap per spec.
- Alert on main via `onMainThread`; setup panel reuses existing helpers.
- Background install when called from `prepareEnvironmentAndShowSettings` global queue.
- Contract test GREEN without manual Rosetta uninstall.

**Risks / follow-ups**
- Full `create-cyder-app.sh` compile not run in this task.
- Manual Apple Silicon test (consent → install → engine) still needed on machine without Rosetta.
- `presentFailure` path for `CYD-ROS-001` inherits existing alert UX (not exercised here).

**Verification**

```bash
bash tests/test-cyder-rosetta.sh
# PASS test-cyder-rosetta
```
