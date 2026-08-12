# Avoid a duplicate resize callback after deminiaturization

Patch: [`patches/a6-r4-deminimize-frame-guard.patch`](../../patches/a6-r4-deminimize-frame-guard.patch)

Suggested upstream title: **winemac.drv: do not report a resize when deminiaturization did not change the frame**

## Problem and reproduction

`windowDidDeminiaturize` unconditionally calls `windowDidResize`. On a restore where Cocoa reports the same frame, this can cause a second geometry/backing update. With Retina coordinate conversion, repeated restore operations may make the window grow or trigger unnecessary OpenGL work.

Reproduce with `bluecg.exe`:

```sh
scripts/run-bluecg.sh --direct
```

Enter the game world, minimize and restore repeatedly, and record the outer frame and client/backing size after each cycle. This patch stores the frame before miniaturization and calls the resize handler only when the frame actually changed.

## Severity and classification

Severity: **Medium**: it affects window geometry and may amplify rendering lifecycle problems, but it is not the primary black-window fix. A6 testing found that R4 alone did not stop the restore-size growth; R5 identified the user32 restore rectangle as the remaining source.

This is a **narrow defensive fix** and a useful upstream discussion, not the final A6 PR.

## Proposed change

Keep the before/after frame comparison, but express the callback contract generically and verify that asynchronous Cocoa frame changes cannot be suppressed accidentally.

## Benefits

- Avoids duplicate resize work when no Cocoa frame change occurred.
- Reduces unnecessary backing synchronization and potential flicker.
- Has a simple, observable predicate that can be tested.

## Costs and risks

- Cocoa may report a frame change asynchronously after the callback; suppressing the callback must not suppress a real client-size update.
- It adds state to `WineWindow` and must be reset on every miniaturize/restore path.
- It does not solve a separate user32-to-Cocoa restore-rectangle conversion bug.

## Complete fix or workaround?

**Partial defensive fix.** It prevents one redundant callback but does not establish the authoritative restore geometry. The current project does not include R4 in the final A6 runtime patch.

## Validation expected in an upstream PR

Use a generic Cocoa test window and verify unchanged-frame restore, changed-frame restore, external resize while minimized, and repeated minimize/restore. Keep R5 as a separate commit so reviewers can see which behavior fixes callback duplication and which fixes geometry authority.
