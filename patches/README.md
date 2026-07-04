# Optional source patches

Applied only when a clean build fails. Prefer proper dependency fixes first.

## W1 — `SONAME_LIBVULKAN` fallback (`w1-win32u-vulkan-soname.patch`)

**Symptom:** `dlls/win32u/vulkan.c: error: use of undeclared identifier 'SONAME_LIBVULKAN'`

**Cause:** configure found neither `libvulkan` nor `libMoltenVK`, so `config.h` never defines `SONAME_LIBVULKAN`, but CrossOver still compiles `vulkan.c`.

**Apply** (from repo root):

```bash
patch -p1 -d sources/wine < patches/w1-win32u-vulkan-soname.patch
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
tar -xOf crossover-sources-26.2.0.tar.gz sources/wine/dlls/win32u/vulkan.c \
  > sources/wine/dlls/win32u/vulkan.c
# or: patch -R -p1 -d sources/wine < patches/w1-win32u-vulkan-soname.patch
```

Then rebuild the affected object / full `make` as needed.

**Better fix (no patch):** install x86_64 MoltenVK into `.brew-x86` and re-run configure so `SONAME_LIBVULKAN` is defined properly.
