# Development and testing guide

How to check a change to the Cyder app layer: offline tests, a local test build,
clicking through the real app, and launching a real game. Release steps
(notarization, publishing) are in [release-pipeline.zh-TW.md](release-pipeline.zh-TW.md);
Wine engine builds are in the sibling `cyder-wine-engine` repo.

## Which check for which change

| Change | Minimum check |
|---|---|
| Shell / Ruby / Python script | The narrowest `tests/test-*`, then `bash tests/run.sh` |
| Swift source (`scripts/cyder_*.swift`) | Typecheck all app sources, the tests that compile that file, then the suite |
| Settings or game-options UI, alerts | Suite **and** click through a test build (tests cannot see layout or main-thread traps) |
| Launch path, graphics install, engine handling | Suite **and** launch a real game from a Developer ID signed test build |
| DirectDraw / cnc-ddraw | The above with BlueCG ([guide](games/bluecg/testing.md)) |
| Engine pin, graphics payloads, version | `release-cyder.sh --channel release` (runs `cyder-release-verify`) |

A hash match, a passing suite or a notarized zip is never evidence that a game
runs. Say "not game-tested" in the report when no game was launched.

## Offline tests

```bash
bash tests/run.sh                 # whole suite, about 160 tests
bash tests/run.sh graphics dxmt   # tests whose name contains a word
bash tests/run.sh --list
```

Run a single test directly with `bash tests/test-<name>.sh`,
`python3 tests/test-<name>.py` or `ruby tests/test-<name>.rb`. The runner writes
one log per test and prints the log directory; pass `--log-dir` to choose it.
The whole suite takes about 12 minutes on the development Mac (many tests
compile Swift), so run it in the background and keep working.

Prerequisites on the development Mac:

- Xcode (not only Command Line Tools) for the Swift tests and app builds.
- `python3` with `PyYAML` (`test-cyder-compatdb-data`) and `Pillow`
  (`test-bluecg-cnc-profile-shader`). Both are test/tooling-only; the shipped
  app needs neither Python nor Apple's developer tools.
- System `ruby`, `perl` and `timeout`. Tests must not require `rg`; use `grep`.
- `install/` and `build/` may be links into `cyder-wine-engine`. Tests that
  need a real engine tree skip or fail when the link target is missing.

Writing tests:

- Source `tests/assert.sh`; create state under `mktemp -d` and remove it in a trap.
- Swift tests compile a subset of the app. When a source file is split, add the
  new file to every test that compiles its dependents (grep `tests/` for the
  old file name).
- Never show real UI or open real apps from a test. Stub `osascript` and `open`
  on `PATH` and assert on what they recorded. A real alert blocks the suite
  until someone dismisses it.
- Do not copy Apple platform binaries (`/bin/sleep`, …) to use as test
  processes; macOS kills them outside their system location. Build a small
  helper instead.
- Call Swift helpers the way the app does. `CyderSwift` subcommands start on the
  main thread, so a harness that only calls them from a background queue hides
  main-thread assertions.
- The launcher runs with `set -E` and an `ERR` trap. A helper that answers with
  a non-zero status inside `$(...)` logs a false `diagnostic event=error`. End
  such substitutions with `|| exit $?` and add an errtrap test.
- Timing assertions compare against a control run on the same machine, not
  against an absolute number.

Baseline on `main` after 0.14.0 (2026-11-12): 157 of 158 pass. Known noise —
rerun a lone failure by itself before treating it as a regression:

- `test-cyder-window-native` opens real windows and reads them through
  Accessibility. It reports `unconfirmed` and fails when another app holds the
  front (for example while someone is using the Mac) or Accessibility is not
  granted to the terminal running it.
- `test-cyder-launch-generation` is timing sensitive under load.

## Typecheck the Swift app without building it

```bash
bash -c 'srcs=($(sed -n "/^SWIFT_SOURCES=(/,/^)/p" scripts/create-cyder-app.sh | grep -o "cyder_[a-z_]*\.swift" | sed "s#^#scripts/#")); swiftc -typecheck -module-cache-path "${TMPDIR:-/tmp}/cyder-typecheck" "${srcs[@]}"'
```

## Local test build

Build into a separate folder so `dist/Cyder.app` (the last release build) is
left alone:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/release-cyder.sh --channel test --out-dir "${TMPDIR:-/tmp}/cyder-test-build"
```

- `DEVELOPER_DIR` is needed when `xcode-select` points at Command Line Tools:
  they can no longer link the Intel half of the universal `CyderSwift`. Setting
  it for one command leaves `xcode-select` unchanged.
- The pinned engine is read from `config/cyder-engine-archive.txt`. If that file
  is missing locally, pass `--engine-archive` with an archive whose SHA-256
  matches `config/cyder-engine-manifest.json` (the engine repo's
  `dist/artifacts/`, or the one inside an existing `Cyder.app`).
- Graphics payloads come from `CYDER_GRAPHICS_ARTIFACTS_DIR` (default
  `dist/artifacts/graphics`, normally a link to the engine repo). Everything in
  that folder is bundled, so it must hold only the DXVK and signed DXMT
  archives you intend to ship or test.

### Which signature a test build needs

| Goal | Signing | Command addition |
|---|---|---|
| Look at windows, settings, alerts | ad-hoc (default) | none |
| Launch a game | Developer ID, not notarized | `--sign-identity "Developer ID Application"` |
| Give the build to anyone else | Developer ID + notarized | use `--channel release` |

An ad-hoc build cannot launch games: the DXMT updater installs graphics only
from an app it can verify as signed by the Cyder Developer ID team, and the
launch stops at graphics preparation with `CYD-WIN-001` and
`{"status":"deferred","reason":"publisher_unverified"}`. A Developer ID test
build also needs the Developer ID signed `dxmt-0.80.tar.zst` in the graphics
folder. Never hand out a Developer ID build that was not notarized.

## Checking the real app

A test build uses the real `~/Library/Application Support/Cyder` settings and
Windows environment. Anything destructive done there (修復, 完全重設, changing a
game's options) acts on the developer's real setup: open those dialogs, read
them, and cancel unless the user asked for the action. Quit the normal Cyder
first, and quit the test build afterwards.

Checks that need no clicking:

```bash
APP="${TMPDIR:-/tmp}/cyder-test-build/Cyder.app"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/CyderSwift"
ENGINE="$HOME/.cyder/runtime/Engines/wine-x86_64"
for c in engine moltenvk gptk; do "$APP/Contents/MacOS/CyderSwift" --runtime-users "$ENGINE" "$c"; echo "$c=$?"; done
```

`--runtime-users` prints 0 when no Wine process uses the engine and 75 when one
does; anything else (for example 133) is a crash to fix before going further.

Clicking through needs macOS permissions that only the user can grant, in
System Settings → 隱私權與安全性: **Screen Recording** to take screenshots and
**Accessibility** (plus the "control System Events" prompt) to send clicks.
Ask, then wait; do not edit the TCC database. Once granted:

- Bring Cyder to the front before every click; answering a prompt puts the
  agent's own window in front.
- Take a new screenshot after each action. Wine windows have no bundle ID or
  accessibility tree, so use `.agents/skills/wine-game-compat-testing/scripts/`
  (`wine-windows.swift`, `guarded-click.swift`, `guarded-key.swift`) for them.
- Restore anything changed for the test (for example a language choice).

### Measuring launch time

The session log gives `operation=wine-prepare elapsed_ms=` and
`operation=wine-launch elapsed_ms=` per launch; compare them with an earlier
version's session logs on the same Mac, not with an absolute number. To see
where the time goes, record every process Cyder starts:

```bash
clang -O1 -o /tmp/launch-timeline .agents/skills/cyder-dev-test/scripts/launch-timeline.c
/tmp/launch-timeline "$(pgrep -x CyderSwift | head -1)" 45 >/tmp/timeline.txt &
open -b local.cyder.app "$HOME/Library/Application Support/Cyder/bottles/shared/drive_c/windows/system32/winver.exe"
wait; sort -n /tmp/timeline.txt | awk '$2 >= 0.25'
```

Columns: start offset, lifetime, pid, parent, command. `open -b` reaches a
translocated app that `open -a <path>` rejects. Do not judge a Finder launch by
"the window appeared after I clicked Cyder": in 0.14.1 the click was a
coincidence with a 30–40 s launch whose progress panel was hidden behind the
frontmost app.

Logs for a launch are in `~/Library/Application Support/Cyder/Logs/`:
`last-launch.log` (latest game run), `sessions/` (app sessions),
`last-error.json`, `engine-install.log`. A clean launch has no
`diagnostic event=error` line.

## Testing a game

1. Read `.agents/skills/wine-game-compat-testing/SKILL.md`: record versions,
   change one variable per run, confirm what was actually loaded.
2. Check the per-game page under [games/](games/README.md) and the
   [compatibility matrix](games/compatibility-matrix.md) for the expected
   backend, launcher chain and known issues.
3. Launch from the Developer ID test build (or the release build) and stop at
   the first screen the user asked about. Logging in, spending, or deleting
   anything in a game needs the user's explicit go-ahead.
4. Report: what was reproduced, what the logs support, what was not tested.

Per-game guides: [BlueCG](games/bluecg/testing.md) (DirectDraw, PE32, cnc-ddraw).
MapleStory engine-level tests are run from `cyder-wine-engine` (its
`incremental-wine-build` skill), not from Cyder.app.

## Working-tree rules

- Scratch and large local data go in `.local/`, `.research/` or outside the
  repo; they are ignored and must never be committed. Check `du -sh .local`
  before a long build: it has grown to hundreds of GB before.
- Keep the checkouts outside `~/Documents`, `~/Desktop` and `~/Downloads`
  (now `~/ogom/Cyderbits` and `~/ogom/cyder-wine-engine`); macOS privacy prompts
  there block long unattended builds.
- Work on a `claude/<topic>` (or `cyder/<topic>`) branch; merge to `main` and
  push only when the user asks.
