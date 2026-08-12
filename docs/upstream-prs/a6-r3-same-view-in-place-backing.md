# Keep same-view OpenGL backing updates in place

Patch: [`patches/a6-r3-same-view-in-place-backing.patch`](../../patches/a6-r3-same-view-in-place-backing.patch)

Suggested upstream title: **winemac.drv: update OpenGL backing sizes in place for the same view**

## Problem and reproduction

The macOS driver currently uses a drawable reset/reattach sequence for backing-size changes. That sequence is appropriate when a context moves to a different view, but is unnecessarily destructive when the context remains attached to the same `NSView`. With explicit backing sizes, a live or programmatic resize can therefore leave a running application with a black surface.

Reproducer: `bluecg.exe` (32-bit DirectDraw through WineD3D/OpenGL).

```sh
scripts/run-bluecg.sh --direct
```

Enter the game world, then test border resize, repeated resize, Alt+Enter in both directions, and minimize/restore. The current project evidence shows the R3 design maintains a visible, full-size image in these cases on the tested CX26/macOS setup.

## Severity and classification

Severity: **High, user-visible rendering failure**. This is the strongest A6 upstream candidate, but the current implementation remains a **candidate correctness fix**: it has broad integration evidence for BlueCG, not yet a Wine regression test covering all OpenGL applications and macOS versions.

## Proposed change

Pass an explicit `allow_in_place` decision to the backing-size update:

- same current view: update the backing size and context in place;
- latent view or a different view: retain the attach/reset behavior;
- a pending deferred update: also use the in-place commit path.

The upstream patch should avoid game-specific names, make the view identity transition explicit, and define what happens when the view is destroyed or the update is queued to the main thread.

## Benefits

- Prevents avoidable `clearDrawable`/`setView` churn during ordinary same-view resizes.
- Preserves the currently visible drawable and improves resize/Alt+Enter robustness.
- Makes the lifetime distinction between same-view resize and view migration clearer in the driver.

## Costs and risks

- In-place CGL behavior may vary across macOS versions and GPU drivers.
- Updating a backing size without recreating all associated state could expose stale drawable metadata if the driver misses another dependent field.
- The current validation is game-led; unrelated OpenGL applications and non-Retina paths still need regression coverage.

## Complete fix or workaround?

The change targets a general lifecycle error rather than changing BlueCG's rendering protocol, so it is best treated as a **probable complete fix for the same-view lifetime bug**. It is not evidence that every macOS black-window report has the same cause.

## Validation expected in an upstream PR

Add a focused winemac/OpenGL regression test or a reproducible test application. The test should exercise same-view resize, view replacement, live resize, and presentation after each operation. Include the BlueCG result as an external integration report, not as the test oracle.
