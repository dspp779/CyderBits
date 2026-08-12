# Preserve original module identity when a DLL is copied to a temporary name

Patch: [`patches/maplestory-cx26-tmp-module-name.patch`](../../patches/maplestory-cx26-tmp-module-name.patch)

Suggested upstream title: **kernelbase: preserve module identity for temporary DLL loads**

## Problem and reproduction

BlackCipher copies a DLL payload to a `.tmp` filename and loads the temporary file. The loader then sees only the temporary basename, while the application/security module expects the original DLL identity. The experiment writes the original source path to `<destination>.msf` during `CopyFileExW` and substitutes that name when `LoadLibraryExW` sees a `.tmp` file.

Target executable: MapleStoryPort `MapleStory.exe` with BlackCipher/NGS enabled. Run from `C:\MapleTest` and capture a narrowly scoped loader/file log:

```sh
MAPLE_WINEDEBUG='-all,+loaddll,+file,+timestamp,+pid,+tid' \
scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
```

The exact OEM launcher may use a different script, but the observable reproducer is a `.dll` -> `.tmp` copy followed by loading the `.tmp`. Verify the `.msf` sidecar, the module name reported by loader traces, and the security module's result. An isolated copy/load EXE should be added before proposing this upstream.

## Severity and classification

Severity: **High for the affected anti-cheat/loader path; unknown for general applications**. The current implementation is a **workaround for a private module-identity protocol**, not yet a complete Windows loader fix.

## Proposed upstream direction

First establish the native Windows observable behavior with a minimal test. If preserving the source identity is required, implement it with explicit metadata and lifecycle rules rather than a global extension-based sidecar:

- make writes atomic and validate the sidecar format and length;
- use a secure association between the temporary file and original name;
- define behavior for rename/delete/race/failure cases;
- ensure malformed or attacker-controlled sidecars cannot redirect arbitrary loads;
- add tests for normal `.tmp` files, missing sidecars and concurrent loads.

## Benefits of the experiment

- Restores the identity expected by the observed loader without changing the payload bytes.
- Keeps normal module loading unchanged when no sidecar exists.
- Makes the private protocol visible and testable in traces.

## Costs and risks

- A generic `.dll` -> `.tmp` rule affects unrelated applications.
- The current sidecar is not atomic, does not authenticate its contents and ignores write errors.
- A source path is not necessarily the same as the Windows module name or loader search result.
- Sidecars may remain after a failed copy or be stale after file replacement.

## Complete fix or workaround?

**Workaround.** Do not submit unchanged. Upstream needs a native-behavior test and a secure, general module-identity design first.
