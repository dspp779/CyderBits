# Implement D3D11 ClearView with rectangular and UAV support

Patch: [`patches/maplestory-cx26-d3d11-full-clear.patch`](../../patches/maplestory-cx26-d3d11-full-clear.patch)

Suggested upstream title: **d3d11/wined3d: implement ClearView rectangles for render, depth and UAV views**

## Problem and reproduction

The CX26 baseline reports `d3d11_device_context_ClearView ... stub!`. Applications that use `ID3D11DeviceContext1/4::ClearView` may therefore leave render targets, depth buffers or UAVs uncleared. A minimal entry-point implementation can make an application progress but is not sufficient: the command stream, GL/Vulkan backends, format conversion, rectangle clipping and compute state invalidation must agree.

The repository has a focused executable:

```text
debug/d3d11-clearview-probe.exe
```

Its source is `debug/d3d11-clearview-probe.c`. It creates an 8x8 `R32G32B32A32_FLOAT` UAV, clears the rectangle `(2,3)-(6,7)`, copies to a staging texture, and verifies that only the requested pixels changed. Run it with the candidate Wine runtime in an isolated prefix, for example:

```sh
WINE=/path/to/wine-runtime/bin/wine
WINEPREFIX="$(mktemp -d)" arch -x86_64 "$WINE" \
  debug/d3d11-clearview-probe.exe
```

For integration evidence, run MapleStoryPort's `MapleStory.exe` from `C:\MapleTest` with the DwarfAxe/overlay path and capture `WINEDEBUG=+d3d11,+wined3d`. The project has observed missing-map/UI artifacts when the full clear group is removed, but has not yet completed an independent upstream-style game test.

## Severity and classification

Severity: **High for D3D11 applications using ClearView**. This is a **candidate complete API implementation**, but the current 1,142-line patch is too broad for one upstream commit.

## Proposed upstream shape

Split the work into reviewable commits:

1. D3D11 entry point and WineD3D public/private API carrying a rectangle array.
2. Command-stream storage and bounds/empty-rectangle handling.
3. OpenGL backend implementation and format conversion tests.
4. Vulkan compute clear, push constants, pipeline-layout cache key, and state invalidation.
5. D3D11 regression tests for RTV, DSV, UAV, no rectangles, multiple rectangles, clipped rectangles and integer formats.

The patch should use general D3D11 semantics rather than mentioning MapleStory in code or commit messages. The existing code's choice to clear a complete UAV when rectangles are supplied is not acceptable for an upstream complete implementation; it is only a diagnostic intermediate.

## Benefits

- Applications receive the documented rectangular clear behavior instead of a stub or full-view approximation.
- The same rectangle representation is preserved across the command stream and both graphics backends.
- Vulkan pipeline layouts include the push-constant range in their cache key, avoiding reuse of an incompatible layout.
- Correct state invalidation prevents the clear compute pipeline from contaminating later draws or dispatches.

## Costs and risks

- It changes WineD3D internal and exported function signatures and therefore needs careful ABI review.
- Backend-specific clear precision and integer/float conversion need tests on both GL and Vulkan.
- A large combined change makes regressions difficult to bisect; upstream should not receive the OEM patch as one opaque commit.

## Complete fix or workaround?

**Complete in intent, incomplete in upstream form.** It is not a workaround: it restores a Windows API contract. The MapleStory result is useful motivation, but the acceptance criterion must be API behavior for arbitrary applications.
