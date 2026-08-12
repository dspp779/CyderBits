# Keep user-memory textures coherent after GPU loads

Patch: [`patches/maplestory-cx26-texture-user-memory-reload.patch`](../../patches/maplestory-cx26-texture-user-memory-reload.patch)

Suggested upstream title: **wined3d: preserve the system-memory source for updated user-memory textures**

## Problem and reproduction

The application supplies texture pixels through user memory. After WineD3D loads the texture, the current location flags can make the GPU copy appear authoritative even though the application has changed the mapped/system-memory pixels. The experiment invalidates the texture location after use so the next access reloads from system memory.

Target executable: MapleStoryPort `MapleStory.exe` with the DwarfAxe/shared-texture path. Run from `C:\MapleTest` with `+wined3d,+vulkan` and compare a texture updated twice through the application-owned memory. The current repository has no isolated user-memory texture EXE; an upstream test is required.

## Severity and classification

Severity: **Medium to High** when affected textures are visible: stale frames, missing UI or corrupted overlays are possible. The current patch is a **workaround**, because it forces a reload rather than modelling the producer's dirty state.

## Proposed upstream change

Preserve a valid system-memory location for user-memory textures and format-conversion uploads, but replace the unconditional post-load invalidation with explicit dirty tracking. The implementation should answer when application writes are visible to WineD3D, which mappings are read-only, and how partial dirty regions interact with Vulkan staging buffers.

## Benefits

- Makes CPU/user-memory writes visible to subsequent GPU reads.
- Avoids treating a stale GPU copy as the only valid location.
- Can support shared-memory and converted-format resources without game names.

## Costs and risks

- Reloading on every use can be expensive for large textures or high frame rates.
- Pinning system memory increases memory pressure and may reduce GPU-only optimization.
- The current hunk is too broad if an application has immutable or read-only user memory.

## Complete fix or workaround?

**Current patch: workaround.** A complete upstream fix requires a documented location/dirty-state transition and focused tests. The MapleStory result is evidence of a coherency problem, not proof that unconditional reload is the correct policy.
