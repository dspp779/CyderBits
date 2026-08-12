# Avoid overwriting a just-restored MapleStory fullscreen style

Patch: [`patches/maplestory-cx26-fullscreen-restore.patch`](../../patches/maplestory-cx26-fullscreen-restore.patch)

Suggested upstream title: **win32u: preserve fullscreen state during a restore transition**

## Problem and reproduction

The application restores its window and shortly afterwards changes the style from `0x94080000` to `0x00ce0000`. On the observed MapleStory path, applying that transition during the three-second restore window loses the renderer's intended fullscreen state.

Target executable: MapleStoryPort `MapleStory.exe`, window class `MapleStoryClass`. Run the game through the appropriate OEM/CX26 test runtime, enter the game or renderer setup, use Alt+Enter or the application's fullscreen/windowed control, and capture `+win,+timestamp,+pid,+tid`. The current patch records `SC_RESTORE`, checks the exact style transition and class name, and ignores that one change for three seconds.

This is an integration reproducer, not a self-contained Win32 test. The upstream PR should add a small test application that issues the same restore/style sequence and asserts the resulting state.

## Severity and classification

Severity: **Medium to High** for the affected renderer: a wrong style transition can leave the game in an unusable fullscreen/windowed state. The current patch is a **game-specific workaround**, not a general win32u correctness fix.

## Proposed upstream direction

Do not retain the MapleStory class name, magic style values or three-second constant in upstream. Instead investigate the window-state transaction: identify whether `SC_RESTORE`, `SetWindowLong(GWL_STYLE)` and renderer state are being applied in the wrong order, and make the transition idempotent for all applications.

If a compatibility rule is still required, it belongs in a narrowly scoped compatibility layer with a documented application rule and a regression test, not in the generic `set_window_long` path.

## Benefits of the current experiment

- Gives a reproducible A/B switch for the observed restore race.
- Avoids changing normal windows unless all three private conditions match.
- Helps separate renderer fullscreen state from the unrelated Cocoa backing-size problem.

## Costs and risks

- The exact style values are not a stable API contract and may vary by version or configuration.
- Ignoring a style change can leave the application and Wine's internal state inconsistent.
- A time-based guard can fail under scheduling delays or remain active longer than intended.
- Putting the policy in `win32u` affects every process and complicates security/state reasoning.

## Complete fix or workaround?

**Workaround.** Upstream value is primarily diagnostic until the state-machine cause is reproduced without MapleStory-specific constants.
