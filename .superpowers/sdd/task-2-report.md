# Task 2 Report: Bundle helper into Cyder.app and switch Swift off python3

## Status

**PASS** — helper bundled, Swift calls `cyder-extract-exe-icon.sh` with `--exe/--png/--wine/--scratch`, timeout is `45`, no `/usr/bin/python3` in the game-library icon path.

## TDD evidence

### RED (Step 2 — tests fail before implementation)

```text
$ bash tests/test-cyder-app-payload.sh
ASSERT_CONTAINS failed: Cyder.app must bundle the winemenubuilder icon helper
  missing: cp "$SCRIPT_DIR/cyder-extract-exe-icon.sh" "$RES/ogom-scripts/"
payload_exit=1

$ bash tests/test-cyder-bottle-shortcuts.sh
ASSERT_NOT_CONTAINS failed: game library icon extraction must not invoke the CLT python3 stub
  unexpected: /usr/bin/python3
shortcuts_exit=1
```

Expected: payload missing helper `cp`; icon store still used `/usr/bin/python3`. Confirmed before production edits.

### GREEN (Step 4 — all three pass after implementation)

```text
$ bash tests/test-cyder-app-payload.sh
PASS test-cyder-app-payload
payload_exit=0

$ bash tests/test-cyder-bottle-shortcuts.sh
PASS test-cyder-bottle-shortcuts
shortcuts_exit=0

$ bash tests/test-cyder-extract-exe-icon.sh   # unsandboxed; wineserver bind
… (MoltenVK init noise) …
PASS test-cyder-extract-exe-icon
extract_exit=0
```

First extract-helper run in the sandbox failed with `wineserver: bind: Operation not permitted` (environmental). Re-run with unrestricted permissions: PASS, including 皮卡丘 integration PNG.

## Files

| File | Action |
|------|--------|
| `tests/test-cyder-app-payload.sh` | Assert helper `cp` + `chmod +x` (replaced py icon-helper assert) |
| `tests/test-cyder-bottle-shortcuts.sh` | Assert no `/usr/bin/python3`, helper name, timeout `45` |
| `scripts/cyder_paths.swift` | `iconExtractRoot` after `sharedBottle` |
| `scripts/cyder_game_icon.swift` | Stage EXE via `FileHandle` into `icon-extract/<id>/game.exe`; call helper; timeout `.now() + 45` |
| `scripts/create-cyder-app.sh` | Copy + chmod helper after `cyder-profile.sh`; left `cyder_create_game_app.py` copy |

Did not rewrite `scripts/cyder-extract-exe-icon.sh` (Task 1 interface).

## Implementation notes

- Helper invocation matches Task 1 CLI exactly: `--exe`, `--png`, `--wine`, `--scratch`.
- `WINEPREFIX` = `CyderPaths.sharedBottle`; `WINESERVER` = engine `bin/wineserver`. Does not kill wineserver.
- Bootstrap guard (missing `.cyder-bootstrap-v1` or wine binary): runs **before** source `FileHandle` / staging. Skip: `completion()`, **no** `failed.insert`, no byte copy. Pending is never inserted.
- Stage failure: `failed.insert` + `game-icon stage-failed`.
- Success still requires `status == 0` and `NSImage(contentsOf: cacheURL) != nil`. Scratch removed on success and failure.
- Timeout written as `.now() + 45` so `assert_contains "$icon" "45"` matches.
- CyderBits `cyder_create_game_app.py` / `cyder_common.py` remain packaged (payload still asserts the common module copy). Game library no longer executes them.

## Self-review

- Header comment is “bundled winemenubuilder helper”; no Python in `cyder_game_icon.swift`.
- Staging uses the granted `FileHandle` (1 MiB chunks); does not reopen the protected source path.
- Process is `/bin/bash` + helper path, not `/usr/bin/python3`.
- Scope limited to the five files in the brief (+ tests). Helper script unchanged.

## Concerns

1. **`tests/test-exe-to-icns.sh`** still says “game library icon extraction should accept an inherited file descriptor” against `cyder_create_game_app.py`. Assertion is on the Python packager, so it still PASSES; message is stale. Task 3 retargets this.
2. **Bootstrap guard was after staging** (fixed in quality-review follow-up). Guard now runs in `ensureExtracted` before `FileHandle(forReadingFrom:)` / `createFile`. On skip: `completion()`, no `failed.insert`, no byte copy.
3. **`assert_contains "$icon" "45"`** is a substring check; satisfied by `.now() + 45`. Fine for this contract test.
4. Extract-helper integration needs an unrestricted environment (wineserver bind). Sandbox-only runs are not a product failure.

## Commit

```
197ae8f feat(app): run game-library icon extraction through Wine
```

Not pushed (per instructions).

## Quality-review follow-up (Important)

Moved `fileExists(CyderPaths.bootstrapMarker)` and wine-binary existence checks to **before** opening the source `FileHandle` / staging. On skip: `completion()`, no `failed.insert`, no copy.

Contract assert in `tests/test-cyder-bottle-shortcuts.sh`: `bootstrapMarker` index must precede `FileHandle(forReadingFrom:)` and `createFile`/`forWritingTo:`.

### GREEN (re-run covering tests)

```text
$ bash tests/test-cyder-bottle-shortcuts.sh
PASS test-cyder-bottle-shortcuts

$ bash tests/test-cyder-app-payload.sh
PASS test-cyder-app-payload
```

Helper CLI, timeout `45`, and python3 absence unchanged.
