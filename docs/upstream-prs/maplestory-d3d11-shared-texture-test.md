# Import a shared D3D11 texture from a named mapping (experimental)

Patch: [`patches/maplestory-cx26-d3d11-shared-texture-test.patch`](../../patches/maplestory-cx26-d3d11-shared-texture-test.patch)

Suggested upstream title: **d3d11: investigate cross-process texture import semantics**

## Problem and reproduction

`ID3D11Device5::OpenSharedResource` is a stub in the target CX26 source. MapleStoryPort's DwarfAxe path exchanges BGRA frame memory through a private `winekmt_<handle>` named mapping. The experimental patch opens that mapping, reads width/height metadata, creates a single-level `DXGI_FORMAT_B8G8R8A8_UNORM` texture and points WineD3D at the mapped pixels. It also adds a command-stream `finish` after flush.

The real reproducer is the MapleStoryPort stack:

```text
MapleStory.exe -> D3D11 -> DwarfAxe.exe / overlay -> OpenSharedResource
```

Build and launch the isolated CX26 experiment with the project workflow, then run from `C:\MapleTest` and capture `+d3d11,+dxgi,+wined3d` logs. Look for `OpenSharedResource`, `Imported shared texture`, the DwarfAxe process, and whether the map/UI becomes visible. The current repository does not contain a standalone producer/consumer EXE for the `winekmt_` protocol; that is an explicit evidence gap.

## Severity and classification

Severity: **High for the observed cross-process renderer, unproven for general Wine**. The patch is an **experimental workaround/protocol port**, not a complete implementation of Windows shared resources.

## Proposed upstream direction

Do not submit the current patch unchanged. First determine the Windows semantics needed by Wine:

- Which `IID`s and resource types must be accepted?
- Which handle type and lifetime rules apply?
- How are format, dimensions, mip levels, array size, sample count, bind flags and synchronization transferred?
- Which process owns the mapping and when are handles/views released?

Then add a synthetic producer/consumer Wine test and implement the generic semantics. The `winekmt_` mapping can remain a compatibility layer only if its wire format is documented and its ownership rules are made safe.

## Benefits of the current experiment

- Confirms that the missing API is on the observed renderer path.
- Provides a narrow A/B knob for separating shared-texture import from ClearView and MoltenVK issues.
- Adds an explicit GPU command completion point before a peer consumes shared memory.

## Costs and risks

- Hardcoded BGRA/2D/one-mip assumptions reject valid resources and can misinterpret foreign handles.
- The mapping is kept alive without a complete resource-release path; this can leak address space and file mappings.
- A `finish` on every flush may reduce throughput and hide a missing synchronization protocol.
- The private named mapping is not evidence that this is how native Windows implements the API.

## Complete fix or workaround?

**Workaround / protocol experiment.** It may be necessary for this product, but it should not be described as a complete upstream shared-resource implementation until the generic contract and tests are established.
