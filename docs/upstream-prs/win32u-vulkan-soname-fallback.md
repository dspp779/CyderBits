# Keep the win32u Vulkan source buildable when Vulkan is not detected

Patch: [`patches/w1-win32u-vulkan-soname.patch`](../../patches/w1-win32u-vulkan-soname.patch)

Suggested upstream title: **win32u: make the Vulkan library name conditional on configure results**

## Problem and reproduction

In the CrossOver build environment, `dlls/win32u/vulkan.c` can be compiled even when configure finds neither `libvulkan` nor `libMoltenVK`. In that case `SONAME_LIBVULKAN` is undefined and compilation fails. The patch supplies the macOS string `libMoltenVK.dylib` as a fallback.

Reproduce with a clean CX26 source and a configure/build configuration where Vulkan development files are absent but `win32u/vulkan.c` remains selected. The project-level dry run is:

```sh
bash scripts/build-wine.sh --cx 26 --dry-run --without-vulkan
```

The upstream test should reproduce the compile-time configuration directly, without relying on the Cyder build wrapper. At runtime, a minimal `win32u`/Vulkan probe should verify both the library-present and library-absent cases.

## Severity and classification

Severity: **Low to Medium**: it blocks a build configuration, while applications that do not use Vulkan may otherwise work. The current change is a **build workaround**, and its runtime fallback can defer an error until `dlopen`.

## Proposed upstream direction

Prefer fixing the configure contract: either do not compile the Vulkan path when the dependency is unavailable, or define a configured library name in the generated header for each supported platform. If the source must compile for a disabled runtime path, make the disabled path explicit and fail with a useful diagnostic when a caller actually requests Vulkan.

## Benefits

- Allows non-Vulkan builds to compile the source tree.
- Keeps the macOS library name in one platform-specific place if the fallback is retained.
- Can improve diagnostics by separating “compiled without Vulkan” from “runtime library missing”.

## Costs and risks

- A fallback can make a build appear Vulkan-capable while the runtime library is absent.
- `libMoltenVK.dylib` is not a portable default for non-macOS targets.
- The patch may mask a configure or generated-header bug rather than fixing it.

## Complete fix or workaround?

**Current patch: workaround.** A complete upstream fix belongs in configure/generated configuration and should include non-macOS and library-absent tests.
