# Task 2 Report: Wine CompatDB Graphics Backends

## Status

DONE_WITH_CONCERNS

## Delivered

- `CYDER_GPTK_ROOT` selects `wine/`, `external/libd3dshared.dylib`, and the D3DMetal framework before falling back to `CYDER_GRAPHICS_BACKENDS_ROOT/lib64/apple_gptk`.
- `CYDER_GRAPHICS_BACKEND` is validated and force-applied after CompatDB DLL rules; resetting the per-rule DLL de-duplication state ensures it supersedes a matched CompatDB backend.
- Corrected the runtime patch's added-file hunk length so the generated `cyder_compat.c` includes its complete trailing functions.

## Verification

- `bash tests/test-cyder-compatdb-wine-runtime.sh` — PASS.
- `bash tests/test-cyder-compatdb-data.sh` — PASS.
- `bash tests/test-cyder-dxvk.sh` — PASS.
- Applied the patch to `build/cx26/sources/wine`, compiled the affected NTDLL/WineD3D targets, and ran `make install` into `install/wine-cx26-x86_64` — PASS.

## Concerns

- `tests/verify-cyder-compatdb-wine-runtime.sh` could not start from this worktree because its hard-coded LLVM-Mingw path does not exist under the worktree (`build/llvm-mingw-...`); the toolchain is present only under the primary checkout. The compile and install verification above succeeded.
- The MapleStory OEM25 Wine source uses incompatible `process.c` hooks, so the shared CompatDB patch is not applicable there; this task rebuilt the CX26 engine that consumes this runtime patch.

## Review Follow-up (2026-07-28)

### Status

FIXED

### Delivered

- Captured the App-provided `CYDER_GRAPHICS_BACKEND` before CompatDB can change the child environment, restored that value into the child environment after rule application, and captured it again before current-process DLL rules run. The captured valid non-default value is then force-applied through `apply_graphics_backend()` after rules, with DLL de-duplication reset so the App selection wins.
- Added a behavioral fixture covering both precedence cases: an explicit App backend wins over a CompatDB backend rule, while the rule still selects a backend if the App provides none.
- Added `patches/cyder-compatdb-runtime-oem25.patch`, an OEM25-specific port. The shared patch fails on OEM25 because two `dlls/ntdll/unix/process.c` hunks conflict with its CrossOver-specific process implementation; the OEM patch uses the compatible OEM process setup and cleanup hooks while retaining the same CompatDB graphics runtime.

### Verification

- `bash tests/test-cyder-compatdb-wine-runtime.sh` — PASS.
- `bash tests/test-cyder-compatdb-data.sh` — PASS.
- `patch --dry-run -p1 < patches/cyder-compatdb-runtime-oem25.patch` in `build/maplestory-oem25/sources/wine` — PASS.

## P1 Follow-up (2026-07-28)

### Status

FIXED

### Delivered

- Removed the duplicate OEM25 `process.c` insertions for `cyder_compat.h`, `struct cyder_compat_result compat`, and `cyder_compat_apply_process_rules()`. The OEM25 hook now captures/applies CompatDB exactly once while retaining the shared capture-then-force graphics backend and `CYDER_GPTK_ROOT` runtime behavior.
- Added a runtime regression assertion that scopes to the OEM25 `process.c` patch section and requires each hook insertion exactly once.

### Verification

- `patch --dry-run --batch -p1 < patches/cyder-compatdb-runtime-oem25.patch` in `build/maplestory-oem25/sources/wine` — PASS.
- `bash tests/test-cyder-compatdb-wine-runtime.sh` — PASS.
- `bash tests/test-cyder-compatdb-data.sh` — PASS.
- OEM25 source tree lacks `config.status` and generated Makefiles, so compiling the NTDLL object was not available.

## Task 2 Blocker Follow-up (2026-07-28)

### Status

FIXED

### Delivered

- Restored the complete tail of the OEM25-added `dlls/ntdll/unix/cyder_compat.c`, including `cyder_compat_apply_current_process_dll_rules()` and `cyder_compat_cleanup_process_rules()`, and corrected its added-file hunk length to 1,619 lines.
- Extended the Wine runtime test to dry-run and apply the OEM25 patch to a clean, minimal copy of the OEM Wine sources, then assert that the resulting `cyder_compat.c` contains the cleanup function and its full cleanup body.

### Verification

- `bash tests/test-cyder-compatdb-wine-runtime.sh` — PASS.
