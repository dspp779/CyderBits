# Do not disable host scheduling yield globally without evidence

Patch: [`patches/maplestory-cx26-no-sched-yield.patch`](../../patches/maplestory-cx26-no-sched-yield.patch)

Suggested upstream title: **ntdll: investigate the host scheduling behavior of NtYieldExecution**

## Problem and reproduction

The patch replaces the `HAVE_SCHED_YIELD` implementation of `NtYieldExecution` with `#if 0`, matching an OEM25 experiment. It prevents the call from yielding the host scheduler, but does not identify a Windows semantic bug or a Wine deadlock.

Target executable: MapleStory Classic `Maplestory_Classic.exe` and its `grap-core64.aes` helper. Use:

```sh
MAPLE_WINEDEBUG='-all,+timestamp,+pid,+tid' \
scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
```

Compare login, enter/leave-game, CPU usage and behavior with and without the patch. The existing MapleStory analysis classifies this change as non-essential for the no-OTP display baseline; there is no current regression EXE or benchmark proving a general benefit.

## Severity and classification

Severity: **Low to Medium**, depending on workload. It changes a process-wide scheduler primitive and could affect latency, CPU usage and fairness for every application.

This is a **performance workaround**, not a complete fix.

## Proposed upstream direction

Do not submit the `#if 0` hunk. First measure `NtYieldExecution` against native Windows semantics and collect a benchmark across CPU-bound, wait-heavy and multimedia workloads. If Wine's current host-yield policy is wrong, make the policy explicit and testable rather than silently disabling it for all applications.

## Benefits of the experiment

- Provides a simple A/B variable for MapleStory scheduler behavior.
- May reduce excessive host yields in one workload.
- Has negligible source complexity.

## Costs and risks

- Can increase CPU consumption and starve other threads.
- May change timing enough to hide or create races.
- Provides no proof that a yield causes the original hang.
- The current evidence does not show that it is needed for MapleStory to render or enter the game.

## Complete fix or workaround?

**Workaround only.** Keep it out of an upstream PR until there is native-semantics evidence and cross-application benchmark data.
