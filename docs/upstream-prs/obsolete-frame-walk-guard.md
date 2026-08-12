# Migration-only: obsolete combined x86_64 frame-walk guard

Patch: [`patches/obsolete/cyder-ntdll-frame-walk-guard.patch`](../../patches/obsolete/cyder-ntdll-frame-walk-guard.patch)

## Status

This patch is **not an upstream PR candidate** and must not be presented as a third implementation of the frame-walk fix. It was the Cyder006 combined patch. The current patch set replaces it with two independently reviewable changes:

1. [`wine-11.1-rtlwalkframechain-null-function.patch`](../../patches/wine-11.1-rtlwalkframechain-null-function.patch) for the missing function entry.
2. [`cyder-ntdll-frame-walk-page-fault-guard.patch`](../../patches/cyder-ntdll-frame-walk-page-fault-guard.patch) for a non-NULL but unreadable entry.

## Reproduction / migration check

The migration behavior is covered by:

```sh
bash tests/test-ntdll-frame-walk-patches.sh
```

That test applies the two replacement patches, confirms the obsolete patch is neither forward- nor reverse-applicable to the migrated source, restores the source, then simulates an old Cyder006 tree and migrates it deterministically.

## Why it should remain out of upstream

- It combines two different claims in one hunk.
- It makes review and later backporting harder.
- The NULL-entry part is already aligned with later Wine behavior and deserves its own upstream history.
- The page-fault part needs a separate discussion about SEH scope and regression coverage.

## Benefit of retaining the file locally

Keeping the patch under `obsolete/` lets the build script recognize old incremental source trees without silently applying an ambiguous historical fix. It is a migration aid only; clean builds must use the split patches.
