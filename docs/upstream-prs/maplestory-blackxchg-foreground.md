# Prevent a transient BlackXchg helper from stealing foreground activation

Patch: [`patches/maplestory-cx26-blackxchg-foreground.patch`](../../patches/maplestory-cx26-blackxchg-foreground.patch)

Suggested upstream title: **winemac.drv: keep transient helper processes from stealing application activation**

## Problem and reproduction

`transformProcessToForeground:` normally brings the shared Wine application to the foreground. The MapleStory anti-cheat helper `BlackXchg.aes` is transient, but it can invoke the same path while MapleStory is creating its renderer window. The helper then steals activation and focus from the game.

Target processes: `MapleStory.exe` and `BlackXchg.aes` (or the corresponding BlackCipher helper in a regional build). Run the OEM/CX26 MapleStory test, capture `+win,+timestamp,+pid,+tid`, and observe the active macOS application and keyboard focus while the renderer window is created. The current patch logs `not bringing BlackXchg.aes to the foreground`; compare it with the unpatched activation trace.

## Severity and classification

Severity: **Medium**: the game may still run, but focus loss can make startup look hung and can send input to the wrong process. The current patch is a **product-specific workaround**.

## Proposed upstream direction

Do not add a process-name check to the generic Cocoa application path. Instead define activation ownership for Wine processes: a helper that shares a Wine session should not become the user-facing foreground application unless it owns a visible top-level window or explicitly requests activation. If that behavior is not generally correct, expose an internal helper-process policy and document its lifetime.

## Benefits of the current experiment

- Prevents the known transient helper from interrupting renderer startup.
- Keeps the change small and easy to A/B.
- Produces a log marker that can confirm whether the helper is the activation source.

## Costs and risks

- Process names and executable URLs are mutable and can be spoofed or localized.
- Some legitimate helper processes may need foreground activation; a name check can break them.
- It does not fix the underlying activation policy or window ownership.
- `NSLog` in a frequently reached application path may add noise and timing changes.

## Complete fix or workaround?

**Workaround.** Keep it in the product compatibility layer unless a generic activation rule and a multi-process test demonstrate the same requirement for other applications.
