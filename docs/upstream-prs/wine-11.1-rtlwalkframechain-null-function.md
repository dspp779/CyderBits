# Stop x86_64 frame walking when no runtime function entry exists

Patch: [`patches/wine-11.1-rtlwalkframechain-null-function.patch`](../../patches/wine-11.1-rtlwalkframechain-null-function.patch)

Suggested upstream title: **ntdll: stop RtlWalkFrameChain when no runtime function is found**

## Problem and reproduction

The x86_64 `RtlWalkFrameChain` implementation passes the result of `RtlLookupFunctionEntry` directly to `RtlVirtualUnwind2`. For code without a registered runtime function entry, the result is `NULL`; unwinding it can fault or produce invalid frame data. A fault in a stack-walk used by an exception handler can recurse into another stack walk.

The repository contains a focused executable reproducer:

```sh
bash tests/test-ntdll-frame-walk-guard.sh
```

The fixture `tests/fixtures/ntdll-frame-walk-guard.c` generates executable code without unwind metadata, calls `RtlWalkFrameChain`, and verifies that the walk stops after the valid frames without writing past the result buffer. The source round-trip test is:

```sh
bash tests/test-ntdll-frame-walk-patches.sh
```

## Severity and classification

Severity: **High**: malformed or absent unwind metadata can turn diagnostics and exception handling into a crash or stack overflow. This is a **small, general correctness fix**, not a MapleStory workaround.

## Proposed change

After each `RtlLookupFunctionEntry`, check for `NULL` and stop the walk before calling `RtlVirtualUnwind2`.

This is intentionally the smallest change. It does not claim that all invalid unwind metadata is safe; the separate page-fault guard addresses that boundary.

## Benefits

- Prevents a direct NULL handoff to the unwinder.
- Makes behavior deterministic for JIT/generated code with no function table.
- Keeps the existing “stop walking on an unwind failure” contract.
- Applies to all x86_64 applications that call the API.

## Costs and risks

- The returned frame list may be shorter than on a native system if a caller expected a leaf frame without a runtime function entry.
- It does not validate a non-NULL but stale or unreadable `RUNTIME_FUNCTION`.
- A Wine regression test should be reviewed for architecture availability and for whether it can register/unregister function tables portably.

## Complete fix or workaround?

**Complete for the NULL-entry bug; intentionally incomplete for malformed metadata.** The patch corresponds to the behavior present in later Wine 11.x sources and should be proposed independently of the Cyder page-fault extension.

## Validation expected in an upstream PR

Keep the missing-entry fixture, add assertions for frame count and output-buffer bounds, and run it both with and without a registered function table. Do not require MapleStory or a proprietary anti-cheat module for acceptance.
