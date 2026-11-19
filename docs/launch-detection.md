# How Cyder decides a launched program started

Agent and developer reference for the launch observation in
`scripts/cyder_app_main.swift` (`observer.wait`), `scripts/cyder_launch_observer.swift`
and `scripts/cyder_launch_support.swift`. Read it before changing when Cyder
shows `CYD-WIN-002` ("程式在顯示視窗前就結束了").

## Signals

After `wine-launch`, Cyder observes the launch for up to 30 seconds. Only one
launch is observed at a time; the next queued launch waits for the result.

| Signal | Source | Result |
|---|---|---|
| A window of the launch's process tree is confirmed and active | status item window scan (`windowConfirmed`), or Wine's activation request accepted for that tree | `activated`: started |
| A window of the tree is on screen, not active | window scan (`windowPresented`) + 1 s grace | `presented`: started |
| The root (the program Cyder started) exits 0 and the environment ends | native root receipt | `finishedWithoutWindow`: no error |
| The root exits non-zero **after** a window was presented | root receipt | `exitedAfterWindow`: no error |
| The root exits non-zero (or by a signal) before any window | root receipt | `rootFailed` → `CYD-WIN-002`/`-003`/`-004` dialog |
| 30 s pass with none of the above | deadline | `unconfirmed`: no dialog |

A window is read from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, owned
by a verified process of the launch tree, at least 80 × 80 and not transparent
(`cyderAcceptsWineWindow`).

An exit code alone cannot decide failure: a launcher or bootstrap (Unreal
Engine's `PenguinHotel.exe`, installers on Cancel) exits 1 when its child is
killed or the user cancels. So an error dialog needs both a non-zero root exit
**and** no window seen first.

## Fixed: fullscreen windows on Wine's raised levels (0.15.0)

winemac.drv (`cocoa_window.m`, `minimumLevelForActive:`) puts a window on:

| Wine window | Level |
|---|---|
| normal | 0 |
| topmost | `NSFloatingWindowLevel` (3) |
| fullscreen, app active | `NSStatusWindowLevel + 1` (26), +1 when topmost |
| displays captured | `CGShieldingWindowLevel() + 1`, +1 when topmost |

Cyder used to accept level 0 only. A fullscreen game (MECCHA CHAMELEON, UE5;
CS2's default exclusive fullscreen) is raised to 26 the moment it becomes the
active app, which happens when Cyder was in front and yielded activation
(`wine activation yielded` in the session log). The launch then had no window
Cyder could see:

- force-quitting the game (bootstrap exits 1) showed a false `CYD-WIN-002`, and
  the open dialog held every later launch until closed (64 s measured);
- left running, the launch stayed unconfirmed for the full 30 s, holding the
  queue.

Measured on M4 / macOS 27.2.1 with a window sampler over all layers: the game
window was layer 26, on screen, 1680 × 945 from 5.4 s after launch; in the
background the same window is layer 0. With the levels above accepted, the
launch is confirmed active about 3.5 s after start, a force-quit at 20 s shows
no dialog (3/3), and a real failure (`find.exe` exiting 2, no window) still
shows `CYD-WIN-002`. Tests: `tests/test-cyder-launch-activation.sh`.

## Still not covered

| Case | What happens | Status |
|---|---|---|
| Window on another Space, or minimized before the scan sees it | `onscreen = false`, the same as Wine's hidden helper windows (a 500 × 500 off-screen window exists in every Wine process), so it is not counted | Open. Counting off-screen windows would also count hidden helpers |
| A launcher hands off to a child and exits non-zero before the child's window appears | `rootFailed` → `CYD-WIN-002` although the child may still start | Open. Handoff executables are listed per launch (`expectsHandoff`) |
| Root exits non-zero after the 30 s observation | Observation already ended (`unconfirmed`); no dialog | By design |
| Wine's activation request without a visible window | Treated as a hint only: the tree and a visible window must be confirmed | By design; relaxing it would accept unverified processes |
| An error dialog is open | Later launch requests wait until it is closed | Unchanged; a real `CYD-WIN-002` still blocks the queue |

## Checking a case

1. Read the session log (`~/Library/Application Support/Cyder/Logs/sessions/`):
   `wine launch window presented`, `wine activation yielded`,
   `stage=wine-activation detail=notification-received`,
   `observation ended without confirmation`, `Cyder error: CYD-WIN-…`.
2. Sample the program's windows over all layers and Spaces with
   `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], …)` and
   record `kCGWindowLayer`, `kCGWindowIsOnscreen`, alpha and bounds every 100 ms.
3. To exercise the fullscreen path, bring Cyder to the front right after the
   launch (`osascript -e 'tell application id "local.cyder.app" to activate'`).
4. After any force-quit, stop if the log shows `CYD-WIN-002`; otherwise new
   launches pile up behind the dialog.
