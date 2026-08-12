# Stop x86_64 frame walking when unwind metadata faults

Patch: [`patches/cyder-ntdll-frame-walk-page-fault-guard.patch`](../../patches/cyder-ntdll-frame-walk-page-fault-guard.patch)

Suggested upstream title: **ntdll: stop x86_64 frame walking when unwind metadata is unreadable**

## Problem and reproduction

Even after checking for a missing `RUNTIME_FUNCTION`, a non-NULL function entry can point to unwind data that is unreadable or concurrently invalidated. `RtlVirtualUnwind2` may then raise a page fault inside `RtlWalkFrameChain`. The caller may be an exception handler, so allowing the fault to escape can create recursive exception handling.

The focused reproducer is:

```sh
bash tests/test-ntdll-frame-walk-guard.sh
```

`tests/fixtures/ntdll-frame-walk-guard.c` registers a runtime function table whose unwind data lies on a page changed to `PAGE_NOACCESS`, calls `RtlWalkFrameChain`, and verifies that the walk stops safely. Run the patch-application round trip with:

```sh
bash tests/test-ntdll-frame-walk-patches.sh
```

## Severity and classification

Severity: **High** in crash-reporting and anti-cheat/exception paths. This is a **defensive correctness fix** for invalid input; it does not repair the producer that supplied stale metadata.

## Proposed change

Execute `RtlVirtualUnwind2` inside Wine SEH, translate a page fault into a failing `NTSTATUS`, and use the existing non-zero-status path to terminate the current frame walk.

The upstream proposal should discuss whether only access violations should be caught, whether the existing `__EXCEPT_PAGE_FAULT` macro has the right scope, and whether the status should be preserved rather than normalized to `STATUS_ACCESS_VIOLATION`.

## Benefits

- Prevents malformed unwind metadata from escaping as a second exception.
- Returns the frames already collected instead of crashing the caller.
- Keeps the failure local to the current walk.

## Costs and risks

- Catching a page fault can hide a real Wine memory bug if the fault is caused by an internal lifetime error rather than foreign metadata.
- SEH around the unwinder adds a non-trivial control-flow boundary to a low-level path.
- The behavior is conservative: it truncates the walk and may reduce diagnostic fidelity.

## Complete fix or workaround?

**Complete as a guard for the reproduced unreadable-metadata case; not a semantic unwind fix.** It should be paired with the upstream NULL-entry patch, not used to justify passing NULL to `RtlVirtualUnwind2`.

## Validation expected in an upstream PR

Add a regression test that can safely protect/unprotect a page containing synthetic unwind data. Test missing entries, readable entries, and unreadable entries separately, and verify that no memory past the caller's frame array is touched.
