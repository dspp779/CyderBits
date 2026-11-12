---
name: cyder-dev-test
description: >-
  Check a change to the Cyder app layer: run the offline test suite
  (tests/run.sh), typecheck Swift, make a local test build, decide whether it
  needs ad-hoc, Developer ID or notarized signing, click through the real app,
  and launch a real game (for example BlueCG). Use after editing scripts/ or
  tests/, when asked to "run the tests", "build and try it", "test it in the
  real Cyder", or "test <game>". Not for shipping a release (cyder-release) or
  Wine engine builds (cyder-wine-engine repo).
---

# Cyder development testing

Full reference: `docs/development-testing.md`. Per-game steps:
`docs/games/<game>/testing.md` (BlueCG: `docs/games/bluecg/testing.md`).

## 1. Offline tests

```bash
bash tests/run.sh <words-from-test-names>   # narrow first
bash tests/run.sh                           # whole suite before committing
```

The whole suite takes about 12 minutes: run it in the background and keep
working. Report failures with the log path the runner prints. Rerun a lone
failure of the known-noise tests (`test-cyder-window-native`,
`test-cyder-launch-generation`) by itself before
calling it a regression. A suite that stops producing output is usually a test showing a
real alert: stub `osascript`/`open` in that test instead of waiting.

After editing Swift, typecheck all app sources (command in the reference doc)
and grep `tests/` for every test that compiles the file you split or renamed.

## 2. Test build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/release-cyder.sh --channel test --out-dir "${TMPDIR:-/tmp}/cyder-test-build"
```

Never build a test into `dist/`: that holds the last release build.

Pick the signature by what the build must do:

| Need | Signature |
|---|---|
| Inspect UI only | ad-hoc (default) |
| Launch a game | add `--sign-identity "Developer ID Application"`; needs the signed `dxmt-0.80.tar.zst` in `CYDER_GRAPHICS_ARTIFACTS_DIR` |
| Leave this Mac | not a test build: `cyder-release` (notarized) |

Ad-hoc builds stop at graphics preparation (`CYD-WIN-001`,
`publisher_unverified`). That is by design; do not weaken the check.

## 3. Real app

- The test build shares the user's real settings and Windows environment. Open
  destructive dialogs (修復, 完全重設) only to read them, then cancel.
- First run the no-click checks (`codesign --verify`, `lipo -info`,
  `CyderSwift --runtime-users`); a crash there (exit 133) blocks everything else.
- Clicking needs Screen Recording and Accessibility, which only the user can
  grant. Ask once, name the setting, and wait. Until then, list the screens for
  the user to click and verify from screenshots.
- Bring Cyder to the front before each click and take a new screenshot after it.
- Afterwards read `~/Library/Application Support/Cyder/Logs/last-launch.log`
  and the newest file in `Logs/sessions/`; any `diagnostic event=error` needs
  an explanation.

## 4. Real game

Follow `.agents/skills/wine-game-compat-testing` and the game's `testing.md`.
Stop at the screen the user asked about. Logging in, spending in-game currency,
deleting data and public comments need the user's explicit go-ahead.

## Report

State separately: tests run and their result, what was checked in the real app,
which game was launched and how far, and what was **not** tested. Never write
"tested" for something only covered by a hash match or a passing suite.

## New knowledge

When a test session teaches something reusable (a new prerequisite, a flaky
test, a game's launch steps), add it to `docs/development-testing.md` or the
game's `testing.md` in the same change.
