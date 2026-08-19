# OEM source packaging compatibility header

> CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

Patch removed from the tree; see git history.

Suggested upstream title: **Do not submit: OEM source-offer packaging compatibility header**

## Problem and reproduction

The OEM source offer expects `include/distversion.h`, but the source archive does not provide it. The patch adds an empty guarded header and lists it in `include/Makefile.in` so the OEM source can be configured or packaged consistently.

Reproduce only with the OEM source offer:

```sh
patch --dry-run -p1 < patches/maplestory-oem25-source-distversion.patch
```

Then run the source's normal configure/make path and compare it with the unpatched archive. This is not a runtime EXE reproducer; it is a source-package compatibility issue.

## Severity and classification

Severity: **Low**, limited to that source offer/build path. This is a **packaging workaround**, not a Wine behavior fix.

## Why it should not go upstream

The header contains no Wine behavior and no general compatibility contract. Upstream should instead decide whether `distversion.h` is generated, remove the stale include, or fix the source archive that references it. Adding an empty header to Wine would carry a vendor-specific packaging artifact into every build.

## Proposed upstream disposition

Close this as a source-offer packaging issue. If the same missing generated header is found in an upstream Wine source tarball, fix the generator or release packaging there instead of adding an empty vendor-specific header.

## Benefits

The local patch makes the OEM source reproducible and keeps generated-file handling explicit. Its cost is that it hides the missing-source-package error and gives no meaningful distribution version. It should remain in the OEM source preparation layer.

## Costs and risks

It can hide a broken source offer and create a meaningless distribution-version contract if copied outside that vendor tree.

## Complete fix or workaround?

**Workaround only; not an upstream PR candidate.**
