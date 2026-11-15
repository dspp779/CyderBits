---
name: cyder-dev-test
description: >-
  Check a change to the Cyder app layer: run the offline tests (tests/run.sh),
  typecheck Swift, make a local test build with the right signature, check the
  real app, and launch a game. Use after editing scripts/ or tests/, or when
  asked to "run the tests", "build and try it", "test it in the real Cyder" or
  "test <game>". Not for shipping (cyder-release) or Wine engine builds
  (cyder-wine-engine repo).
---

# Cyder development testing

Reference with full detail: `docs/development-testing.md`.

Do the steps in order and stop at the first one that fails. Steps 3–5 are
needed only when the change is visible in the app or affects launching.

## 1. Run the tests

```bash
bash tests/run.sh <word-from-the-test-names>
```

```bash
bash tests/run.sh
```

1. Run the narrow set first, then the whole suite in the background (about
   12 minutes). The runner prints each failing test's log path.
2. After editing Swift, typecheck every app source (command in the reference)
   and grep `tests/` for tests that compile a file you split or renamed. They
   compile a subset of the app, so a new file must be added to each of them.
3. If a test fails: rerun it alone three times and read its assertion.
   - Fails every time → a regression or a stale assertion. Fix it; do not call
     it flaky.
   - `test-cyder-window-native` and `test-cyder-launch-generation` depend on
     window focus and load; they may fail while the Mac is in use.
4. If the suite prints nothing for minutes, a test has opened a real alert.
   Stub `osascript` and `open` in that test; do not wait or click it away.

When writing tests:

- Call Swift helpers from the main thread, as the app does. A harness that only
  used a background queue hid a main-thread crash (exit 133) that would have
  refused every MoltenVK switch in the shipped app.
- Do not copy `/bin/sleep` or other Apple binaries as test processes; macOS
  kills them outside their system location.
- In the launcher (`set -E` + `ERR` trap), a helper that answers with a
  non-zero status inside `$(...)` logs a false error. End the substitution with
  `|| exit $?`.
- Do not read Wine's output through a pipe: its background services keep the
  pipe open and the read never ends. Write to a file with a time limit.
- Compare timings with a control run, never with an absolute number. For
  launch time, use `scripts/launch-timeline.c` (steps in the reference,
  "Measuring launch time").
- Use `grep`, not `rg`.

## 2. Build a test app

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/release-cyder.sh --channel test --out-dir "${TMPDIR:-/tmp}/cyder-test-build"
```

- Always pass `--out-dir` outside `dist/`; `dist/` holds the last release build.
- `DEVELOPER_DIR` is required when `xcode-select` points at Command Line Tools,
  which cannot link the Intel half of the app.
- To **launch a game**, add `--sign-identity "Developer ID Application"`. An
  ad-hoc build stops at graphics preparation (`CYD-WIN-001`,
  `publisher_unverified`) because the DXMT updater only trusts an app signed by
  the Cyder team. That is intended; never weaken it.
- If the pinned engine archive is missing, pass `--engine-archive` with one
  whose SHA-256 matches `config/cyder-engine-manifest.json`.

## 3. Check the app without clicking

```bash
APP="${TMPDIR:-/tmp}/cyder-test-build/Cyder.app"; codesign --verify --deep --strict "$APP" && lipo -info "$APP/Contents/MacOS/CyderSwift" && "$APP/Contents/MacOS/CyderSwift" --runtime-users "$HOME/.cyder/runtime/Engines/wine-x86_64" engine; echo "runtime-users=$?"
```

`runtime-users` must print 0 (idle) or 75 (in use). Anything else is a crash;
fix it before going on.

## 4. Click through the app

The test build uses the user's **real** settings and Windows environment.

1. Quit the normal Cyder, then open the test build.
2. Screenshots need Screen Recording; clicks need Accessibility. Only the user
   can grant them: name the setting, ask once, and wait. Meanwhile give the
   user the list of screens to open.
3. Before each click bring Cyder to the front (answering a prompt puts another
   window in front, and a first click on a background window only focuses it).
   Take a new screenshot after each action.
4. Open 修復 and 完全重設 only to read them, then cancel. Change game options
   only if asked, and restore anything changed for the test.
5. Quit the test build when done.

## 5. Launch a game

1. Follow `docs/games/<game>/testing.md` (BlueCG has one) and the
   `wine-game-compat-testing` skill.
2. Stop at the screen the user asked about. Logging in, spending in-game
   currency and deleting data need the user's explicit go-ahead.
3. Read `~/Library/Application Support/Cyder/Logs/last-launch.log` and the
   newest file in `Logs/sessions/`. Explain every `diagnostic event=error`.

## 6. Report

List separately: tests run and result; screens checked; game launched and how
far; and what was **not** tested. If no game was launched, say so.

If the session taught something reusable (a prerequisite, a trap, a game's
steps), add it to `docs/development-testing.md`, the game's `testing.md` or
this skill in the same change.
