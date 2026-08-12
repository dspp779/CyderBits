# Update the final OpenGL backing size in place

Patch: [`patches/a6-r2-in-place-final-backing.patch`](../../patches/a6-r2-in-place-final-backing.patch)

Suggested upstream title: **winemac.drv: update a pending OpenGL backing size in place**

## Problem and reproduction

R1 defers a resize, but the first final synchronization still follows the normal backing-size path. On macOS, resetting the drawable at that point can detach the surface that is already visible. The application continues running while the window becomes black.

Reproduce with `bluecg.exe`:

```sh
scripts/run-bluecg.sh --direct
```

After entering the world, perform a live resize and then release the mouse. Test both a Retina/high-DPI display and a non-Retina configuration. The expected baseline failure is a black or stale window immediately after the final resize commit.

## Severity and classification

Severity: **High** for applications using explicit backing sizes. This is a **design refinement** of R1 and is not a standalone upstream PR: R3 supersedes it by applying the same in-place rule to every same-view resize.

## Proposed change

When the context has a pending final synchronization, set the view backing size and call the existing context update without clearing the drawable or attaching a replacement view. Reset the pending bit only after the update has completed.

For upstream, the condition should be expressed in terms of view identity and drawable ownership, not “final resize” alone. A different view still needs the existing attach/reset path.

## Benefits

- Keeps the current drawable alive while changing its backing dimensions.
- Reduces the chance that a final resize loses the visible surface.
- Separates “resize the same drawable” from “move a context to another view”.

## Costs and open questions

- The patch does not yet cover programmatic same-view resizes; R3 is needed for that.
- Cocoa/OpenGL implementations differ across macOS releases, so an in-place update must be checked against older supported systems.
- A test must distinguish a valid in-place update from a resize that really changes the context's view.

## Complete fix or workaround?

**Partial correctness fix.** It removes one destructive final-sync path, but R3 is the general same-view formulation and should be the basis of any upstream proposal.

## Validation expected in an upstream PR

Use an automated OpenGL window test where possible, plus the BlueCG integration sequence: drag resize, release, Alt+Enter, and minimize/restore. Record whether the same `NSView` and `NSOpenGLContext` remain attached before and after the operation.
