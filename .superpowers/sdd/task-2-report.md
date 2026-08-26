# Task 2 Report: Swift Rosetta helper + stage + build wiring + contracts

**Branch:** `feat/rosetta-consent-install`  
**Date:** 2026-08-25

## Summary

Added `CyderRosetta` Swift helper with Apple Silicon detection (uname Process variant), installed check, and consented `softwareupdate --install-rosetta --agree-to-license` install. Registered `CyderStage.rosettaCheck`, wired compile into `create-cyder-app.sh`, and extended contract tests.

## TDD cycle

| Step | Result |
|------|--------|
| Append Task 2 contract asserts | Done — before final `PASS` |
| RED | `cat: cyder_rosetta.swift: No such file or directory` |
| Implement | Swift helper, stage, build wiring |
| GREEN | `PASS test-cyder-rosetta` (exit 0) |

## Files changed

| File | Change |
|------|--------|
| `scripts/cyder_rosetta.swift` | **New** — `CyderRosetta` enum |
| `scripts/cyder_diagnostics.swift` | `case rosettaCheck = "rosetta-check"` |
| `scripts/create-cyder-app.sh` | Added to `SWIFT_SOURCES` after `cyder_launch_support.swift` |
| `tests/test-cyder-rosetta.sh` | Task 2 contract asserts (5 checks) |

## Interfaces delivered

```swift
enum CyderRosetta {
    static var isAppleSilicon: Bool   // uname -m == arm64
    static var isInstalled: Bool      // pkgutil + arch -x86_64 fallback
    static func installWithAgreedLicense() -> (ok: Bool, detail: String)
}

enum CyderStage {
    case rosettaCheck = "rosetta-check"
}
```

## Contract asserts (Task 2 only)

- Swift helper invokes `/usr/sbin/softwareupdate` with `--agree-to-license`
- Swift exposes `static var isInstalled`
- Diagnostics defines `rosettaCheck` stage
- App build compiles `cyder_rosetta.swift`

Runtime Rosetta ensure / `CYD-ROS-001` / `ensureEnvironment` wiring intentionally **not** included (Task 3).

## Commit

```
feat(app): add Swift Rosetta detect and consented install helper
```

## Self-review

**Strengths**
- Matches brief exactly; uname Process variant per controller resolution.
- Contract asserts run without runtime Rosetta install (static source checks after optional runtime block).
- `installWithAgreedLicense` documents caller consent requirement; post-install verification via `isInstalled`.
- Build wiring placement follows existing `SWIFT_SOURCES` order.

**Risks / follow-ups (Task 3+)**
- Helper is not yet called from `ensureEnvironment`; no UI consent flow or `CYD-ROS-001` yet.
- Swift compile not verified in this task (full `create-cyder-app.sh` build not run).
- `installWithAgreedLicense` untested at runtime (would require Rosetta uninstall or mock).

**Verification**

```bash
bash tests/test-cyder-rosetta.sh
# PASS test-cyder-rosetta
```
