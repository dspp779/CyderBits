# Defer OpenGL backing-size synchronization during live resize

Patch: [`patches/a6-r1-resize-end-backing-sync.patch`](../../patches/a6-r1-resize-end-backing-sync.patch)

Suggested upstream title: **winemac.drv: defer OpenGL backing-size changes until live resize completes**

## Problem and reproduction

On the macOS OpenGL path, a window resize can change the Cocoa view backing size while Wine is still receiving live-resize callbacks. The current path may repeatedly reset the `NSOpenGLContext` drawable. Affected applications remain alive but present a black window after an in-game resize.

The original reproducer is the 32-bit DirectDraw game `bluecg.exe` (BlueCG / 水藍魔力):

```sh
scripts/run-bluecg.sh --direct
```

Enter the game world, drag the window border several times, and compare a baseline CX26 engine with an engine containing this patch. Also test Alt+Enter and minimize/restore. The useful diagnostic window is `winemac.drv`'s `wine_updateBackingSize()` / `macdrv_window_resize_ended()` path; a black window with the process still alive is the key symptom.

## Severity and classification

Severity: **High, user-visible rendering regression**. The failure is not a crash, but it makes an otherwise running application unusable after a normal window operation.

This patch is a **partial correctness fix**, not a complete upstream-ready change. It defers synchronization during live resize and commits it after `WM_EXITSIZEMOVE`, but later revisions were needed to make same-view updates safe and to preserve user32 restore geometry.

## Proposed change

Track a per-view deferred state and a per-context pending state. During `windowWillStartLiveResize`, suppress backing-size invalidation. At resize end, mark affected OpenGL contexts pending and force the next context update before presenting again.

The upstream version should generalize the state machine to all OpenGL views, avoid the MapleStory/BlueCG assumption, and document the thread/main-queue ownership of the Cocoa operations.

## Benefits

- Avoids repeated drawable teardown while Cocoa is in a live-resize transaction.
- Preserves the final backing size instead of letting intermediate sizes race with presentation.
- Provides an explicit synchronization point that can be tested independently of a particular game.

## Costs and open questions

- A deferred update can leave rendering at the previous backing size during the drag.
- The current patch traverses subviews and carries state between Cocoa and C driver code; this needs review for view lifetime and thread safety.
- R2 and R3 show that simply forcing a later update is insufficient if the final update still destroys the current drawable.

## Complete fix or workaround?

**Partial correctness fix.** It addresses the timing of backing synchronization, but the current patch is superseded by the same-view in-place policy in R3 and the restore-rectangle rule in R5.

## Validation expected in an upstream PR

Add a small winemac regression scenario or a maintainer-reproducible test that creates an OpenGL window, changes its backing scale/size during live resize, and verifies that presentation resumes. The BlueCG run is valuable integration evidence, but cannot be the only test.
