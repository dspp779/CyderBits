# Task 3 Report: Stop treating PE stdin extract as the game-library path

**Date:** 2026-08-19  
**Branch:** `feat/exe-icon-winemenubuilder`  
**Scope:** Test assertion message only (no product code)

## Objective

Align `tests/test-exe-to-icns.sh` with the new architecture: game-library icon extraction runs through Wine/menubuilder (Tasks 1–2), while `--extract-icon-stdin` remains a CyderBits packager capability—not the game-library path.

## Changes

### `tests/test-exe-to-icns.sh` (line 14)

**Before:**
```bash
assert_contains "$content" '"--extract-icon-stdin"' "game library icon extraction should accept an inherited file descriptor"
```

**After:**
```bash
assert_contains "$content" '"--extract-icon-stdin"' "CyderBits packager may still extract PE icons from stdin"
```

The assertion still verifies that `scripts/cyder_create_game_app.py` exposes `--extract-icon-stdin`; only the human-readable failure message was updated to stop implying the game library uses Python stdin extraction.

## Verification

```bash
bash tests/test-exe-to-icns.sh
# PASS test-exe-to-icns
```

No iconutil integration run in this environment (no `dist/BlueLauncher.exe` and/or `iconutil`); static string assertions all passed.

## Commit

```
test: stop treating PE stdin extract as the game-library path
```

Single file: `tests/test-exe-to-icns.sh`. Not pushed.

## Self-review (Task 3 row)

| Spec | Status |
|------|--------|
| `--extract-icon-stdin` relabeled as CyderBits, not game library | Done |
| No engine / Dock / CyderBits GUI changes | N/A |
| No product code changes | Confirmed |

## Notes

Other assertions in the same file (e.g. `def exe_to_png(` with message "game library should reuse the PE icon extractor") were left unchanged per brief; Task 3 only covered the `--extract-icon-stdin` message.
