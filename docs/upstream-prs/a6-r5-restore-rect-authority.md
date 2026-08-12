# Preserve the user32 restore rectangle during Cocoa unminimize

Patch: [`patches/a6-r5-preserve-user32-restore-rect.patch`](../../patches/a6-r5-preserve-user32-restore-rect.patch)

Suggested upstream title: **winemac.drv: do not replace the user32 restore rectangle on unminimize**

## Problem and reproduction

During `WINDOW_DID_UNMINIMIZE`, `macdrv_ShowWindow` treats the Cocoa frame as an externally changed frame and writes it back over the rectangle calculated by user32. On Retina displays, the Cocoa-to-Win32 conversion can apply the scale a second time. Repeated minimize/restore then grows the outer window instead of restoring the saved normal rectangle.

Reproduce with `bluecg.exe`:

```sh
scripts/run-bluecg.sh --direct
```

Use a Retina/high-DPI setting, enter the game world, minimize and restore several times, and compare the outer frame after each cycle. The patched behavior keeps the size stable while still accepting a genuine `WINDOW_FRAME_CHANGED` event.

## Severity and classification

Severity: **Medium to High** for high-DPI applications: the window may become unusable after repeated restore operations. This is a **candidate complete fix for the specific restore-rectangle ownership bug**, separate from the OpenGL drawable fix.

## Proposed change

Only query the Cocoa frame for `WINDOW_FRAME_CHANGED`. For `WINDOW_DID_UNMINIMIZE`, leave the rectangle produced by user32's minimize/restore state machine untouched.

The upstream PR should explain the ownership rule: user32 owns the saved normal position; Cocoa supplies geometry only when it reports a real external frame change.

## Benefits

- Prevents double application of Retina scale during restore.
- Keeps repeated minimize/restore idempotent.
- Avoids special-casing a game class or a particular DPI value.

## Costs and risks

- If a platform reports a real frame change only with the unminimize event, the change could miss that geometry update; this needs a platform-version test.
- The patch is small but depends on the event ordering between Cocoa, win32u and user32.
- It does not by itself repair a black drawable after resize.

## Complete fix or workaround?

**Candidate complete fix for the restore-rectangle ownership bug.** It is not a workaround for rendering; it leaves the broader OpenGL backing lifecycle to A6-R3.

## Validation expected in an upstream PR

Test an ordinary resizable OpenGL window at scale 1 and scale 2, with repeated minimize/restore and an external resize between cycles. Include a trace showing the event type and the rectangle source. BlueCG is an integration reproducer, not a reason to retain game-specific code.
