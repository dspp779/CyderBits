# Reject invalid DWARF division and modulo operations safely

Patch: [`patches/maplestory-cx26-dbghelp-dwarf-guard.patch`](../../patches/maplestory-cx26-dbghelp-dwarf-guard.patch)

Suggested upstream title: **dbghelp: handle zero divisors in DWARF location expressions**

## Problem and reproduction

The DWARF evaluator executes `DW_OP_div` and `DW_OP_mod` without checking the divisor. Malformed, incomplete or incompatible debug information can therefore raise a host divide-by-zero exception while Wine is trying to produce a crash report.

The observed integration reproducer is MapleStory Classic `Maplestory_Classic.exe` with its `grap-core64.aes`/crash-reporting path and a retail-style dbghelp build. Use a short, low-overhead log first:

```sh
MAPLE_WINEDEBUG='-all,err+all,+timestamp,+pid,+tid,+dbghelp' \
scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
```

The repository does not yet contain a minimal malformed-DWARF file or standalone dbghelp EXE. An upstream PR should add one, or adapt an existing dbghelp test, so the result does not depend on a proprietary crash reporter.

## Severity and classification

Severity: **Medium** for ordinary applications, but potentially **High during crash handling** because a diagnostic failure can replace the original failure with a second crash. This is a **complete defensive fix for the zero-divisor case**, not a workaround for MapleStory.

## Proposed change

Before `DW_OP_div` or `DW_OP_mod`, validate the divisor. Emit a warning and return the evaluator's internal-location-error result when it is zero. Keep valid expressions unchanged.

The upstream version should also review stack underflow/overflow checks around the same opcode family and decide whether invalid DWARF should be logged at `WARN` or a quieter level.

## Benefits

- Prevents a host arithmetic exception from escaping the debug evaluator.
- Preserves the original crash path and lets callers report invalid debug information.
- Does not disable normal symbol initialization or all DWARF support.

## Costs and risks

- A caller may receive less precise location information for malformed debug data.
- The warning can be noisy if a producer emits invalid expressions repeatedly.
- The current patch fixes only zero division/modulo; it should not imply that all malformed DWARF is handled.

## Complete fix or workaround?

**Complete defensive fix for the reproduced zero-divisor case.** It preserves valid DWARF behavior and reports an evaluator error for invalid expressions; it does not repair malformed debug data at its source.

## Validation expected in an upstream PR

Test valid signed/unsigned division and modulo, zero divisors, empty/underflowed stacks and repeated evaluation. Verify that the evaluator returns an error without crashing the process.
