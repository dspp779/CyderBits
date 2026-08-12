# Produce a cross-process handle for a DXGI resource (experimental)

Patch: [`patches/maplestory-cx26-dxgi-shared-handle.patch`](../../patches/maplestory-cx26-dxgi-shared-handle.patch)

Suggested upstream title: **dxgi: define and implement resource-sharing ownership semantics**

## Problem and reproduction

`IDXGIResource1::GetSharedHandle` is a stub in the target source. The experiment allocates a handle-like value, creates a named `winekmt_<handle>` file mapping, stores width/height metadata followed by pixel memory, and points the WineD3D texture at that memory. It is intended to be the producer side for DwarfAxe consumers.

The reproducer is the MapleStoryPort `MapleStory.exe` + DwarfAxe renderer path, with the same isolated CX26 build used for the D3D11 shared-texture experiment. Capture `+dxgi,+d3d11,+wined3d` and verify whether `GetSharedHandle` is called, whether the same handle is returned on repeated calls, and whether the consumer can import and present the frame. There is currently no standalone producer/consumer test in this repository.

## Severity and classification

Severity: **High only if an application relies on Wine as the resource producer; current evidence is conditional**. This patch is a **private protocol workaround**, not an upstream-ready implementation.

## Proposed upstream direction

First establish whether the target application actually requires Wine's producer side. Existing investigation shows the current CX26 path may be a DwarfAxe consumer path, so implementing `GetSharedHandle` speculatively can expand the attack surface without fixing the observed black screen.

If general support is needed, implement a documented resource-sharing abstraction with:

- validated resource descriptors;
- per-resource handle allocation and collision handling;
- reference-counted mapping/view lifetime;
- synchronization between producer and consumer;
- correct behavior for unsupported resource types;
- a two-process Wine regression test.

## Benefits of the experiment

- Makes the missing producer capability observable in a real application.
- Gives a concrete A/B point for determining whether DwarfAxe or Wine owns the shared-memory protocol.
- Can become a useful compatibility layer if the protocol is documented and safely scoped.

## Costs and risks

- The current global counter and `sprintf` name scheme are not a Windows handle implementation.
- Mapping lifetime is incomplete and can leak for every shared resource.
- The code returns `S_OK` for behavior that is explicitly partial and does not validate all resource descriptors.
- Adding producer support before proving it is needed may make future semantics harder to change.

## Complete fix or workaround?

**Workaround / investigation aid.** Do not submit the current patch as a general DXGI implementation. A standalone test and a clear ownership model are prerequisites.
