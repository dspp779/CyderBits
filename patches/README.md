# Optional source patches

Applied only when a clean build fails. Prefer proper dependency fixes first.

## W1 — `SONAME_LIBVULKAN` fallback (`w1-win32u-vulkan-soname.patch`)

**Symptom:** `dlls/win32u/vulkan.c: error: use of undeclared identifier 'SONAME_LIBVULKAN'`

**Cause:** configure found neither `libvulkan` nor `libMoltenVK`, so `config.h` never defines `SONAME_LIBVULKAN`, but CrossOver still compiles `vulkan.c`.

**Apply** (from repo root, CX26 example):

```bash
patch -p1 -d build/cx26/sources/wine < patches/w1-win32u-vulkan-soname.patch
```

The patch adds:

```c
#ifndef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "libMoltenVK.dylib"
#endif
```

after `#include "config.h"` (not a bare `sed` replace of every identifier).

**Restore:**

```bash
tar -xOf tools/archives/crossover-sources-26.2.0.tar.gz sources/wine/dlls/win32u/vulkan.c \
  > build/cx26/sources/wine/dlls/win32u/vulkan.c
# or: patch -R -p1 -d build/cx26/sources/wine < patches/w1-win32u-vulkan-soname.patch
```

Then rebuild the affected object / full `make` as needed.

**Better fix (no patch):** enable Vulkan when building Wine:

```bash
# Homebrew MoltenVK (fast path)
bash scripts/build-wine.sh --install-deps --with-vulkan --vulkan-source homebrew
bash scripts/build-wine.sh --with-vulkan --vulkan-source homebrew

# CrossOver FOSS MoltenVK (version-locked to CX tarball)
bash scripts/build-graphics-stack.sh --cx 26 --install-deps
bash scripts/build-graphics-stack.sh --cx 26
bash scripts/build-wine.sh --with-vulkan --vulkan-source crossover
```

To skip Vulkan entirely (BlueCG default): `--without-vulkan`.

## BlueCG A6 — same-view backing sync

`a6-final-same-view-backing-sync.patch` is the consolidated CrossOver 26.2.0
patch for the BlueCG Retina+DPI resize fix. It combines the tested R1, R2, R3
and R5 changes; the R4 deminiaturize guard remains history-only and should not
be applied to the final engine. See
[`docs/bluecg-winemac-a6-engine.md`](../docs/bluecg-winemac-a6-engine.md) for
the tested runtime and artifact checksum.
