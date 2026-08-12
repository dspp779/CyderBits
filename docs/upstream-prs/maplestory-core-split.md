# Split the mixed MapleStory CX26 core patch into independent upstream topics

Patch: [`patches/maplestory-cx26-core.patch`](../../patches/maplestory-cx26-core.patch)

Suggested upstream title: **MapleStoryPort core compatibility changes** — **do not use this title for a single Wine PR**

## Why this patch must be split

The 272-line file combines three unrelated changes:

1. `wined3d` user-memory and format-conversion texture behavior;
2. a new `winegstreamer` `rawaudioparse` element selected by `RAW_AUDIO_PARSE=1`;
3. `winemac.drv` special handling for the `MapleStoryClass` window and size/move loop.

They have different owners, tests, severity, and upstream acceptance criteria. A single PR would make a successful MapleStory run impossible to attribute and would force unrelated application-specific policy into general Wine code.

## Reproduction matrix

### Texture path

Target executable: MapleStoryPort `MapleStory.exe`, with DwarfAxe/overlay and the WineD3D/Vulkan renderer. Run from `C:\MapleTest`, capture `+wined3d,+vulkan`, and compare a texture written through user memory or a format-conversion upload. The expected failure is stale or missing GPU content after the application updates the mapped pixels.

### Raw audio path

Target executable: the same MapleStory `MapleStory.exe` startup/audio path. Use an isolated prefix with:

```sh
RAW_AUDIO_PARSE=1 \
  scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
```

The existing launcher is for Classic and the exact OEM launcher may differ; the upstream PR needs a small GStreamer/Wine test pipeline that feeds `audio/x-raw` and checks frame duration rather than requiring the game.

### Window path

Target executable: `MapleStory.exe` / window class `MapleStoryClass`.

```sh
scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
```

Enter the game world, attempt a border resize and observe whether macOS live-resize changes the game window. This behavior is intentionally game-specific in the current patch and should not be copied upstream without a generic policy.

## Severity and classification

The combined file is **Mixed**: visual corruption can be High, raw audio compatibility Medium, and the window policy Medium. As a whole it is a **porting bundle**, not a complete upstream fix.

## Proposed split

### A. User-memory texture correctness

Keep the principle that CPU-visible/user-memory textures with upload conversion need a valid system-memory source. Replace the unconditional pin/reload behavior with correct dirty-region and location tracking. Add a test that writes mapped pixels, issues a draw, updates them again, and verifies the second image.

### B. Raw PCM parser

Submit a general `winegstreamer` parser only if the Windows media behavior and GStreamer pipeline contract are demonstrated independently. Define caps negotiation, frame duration, unsupported formats and the opt-in policy. `RAW_AUDIO_PARSE=1` may be useful for A/B, but an upstream PR should not silently change every `audio/x-raw` pipeline.

### C. Window policy

Do not upstream `MapleStoryClass` checks. If live-resize suppression is generally needed, add a driver-level opt-in or fix the underlying Cocoa resize lifecycle. The current A6 documents are a more promising general path for the black-window problem.

## Benefits of splitting

- Each change gets a focused reviewer and regression test.
- The texture fix can be judged on correctness and performance rather than audio/window side effects.
- The raw parser can be discussed with the winegstreamer maintainers independently.
- Game-specific window policy remains in the compatibility layer until a general driver rule is proven.

## Costs and risks

- Splitting requires separate source preparation and A/B runs for each subsystem.
- The texture and renderer paths may still have an interaction, so a final integration run remains necessary after the focused tests pass.

## Complete fix or workaround?

The file is neither. It contains potential complete fixes, conditional support and workarounds. Upstream should receive only the independently justified portions.
