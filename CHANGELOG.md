# Changelog

Notable changes to Cyder. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). Each entry links to the full
release notes in [`docs/releases/`](docs/releases/); the engine column refers to
[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine).

## [Unreleased]

### Removed
- Support for macOS 10.15 and 11. Releases after 0.14 require macOS 12 or later.

## [0.14.1] - 2026-11-13

Engine `CX26.3.0-W11-Cyder013`, rebuilt for older macOS compatibility.
Draft notes: [繁中](docs/releases/v0.14.1.md) · [English](docs/releases/v0.14.1.en.md).

### Fixed
- Environment update crashes caused by system functions unavailable on older macOS (engine #14); engine archive fingerprints trigger the same-version update.
- Relaunch failures when a background status update briefly holds the executor catalog.
- The launch progress window hidden behind the active app when an .exe is opened from Finder; the component integrity check runs once per launch ([#24](https://github.com/dspp779/CyderBits/pull/24)).

## [0.14.0] - 2026-11-12

Engine `CX26.3.0-W11-Cyder013` (CrossOver 26.3.0 FOSS, Wine 11.0). Last release for macOS 10.15 and 11.
Full notes: [繁中](docs/releases/v0.14.0.md) · [English](docs/releases/v0.14.0.en.md).

### Added
- Per-game cnc-ddraw switch with Bicubic and Lanczos filters, using the engine's `native-ddraw-path-v1`.
- Per-EXE scroll-wheel mode with an optional precise-scrolling setting.
- "Repair" (keeps the environment) and "Full Reset" (clears it, can be undone), replacing "Rebuild".
- Cities: Skylines II DXMT candidate rule (off by default).
- Engine: wined3d OpenGL Shader Model 5 (feature level 11), off by default.
- Component integrity diagnostics cover the environment's Wine system files (#20).

### Changed
- Quitting Cyder no longer requires ending running games; stopping the Windows environment is a separate action.
- Launch preparation takes about 0.4 s instead of about 1.8 s; menus and the Game Library do their I/O in the background.
- State updates are event-driven instead of polled every second.
- MoltenVK/GPTK cannot be switched while programs are running on the engine.
- DXMT is packaged under its upstream version `0.80` (was `0.80-cyder.N`); `winemetal.so` is Developer ID signed.
- MoltenVK 1.2.10 reuses Cyder012's macOS 10.15 build so DXVK still works on macOS 10.15/11.

### Fixed
- Black textures with DXVK on Intel/AMD GPUs in TMS MapleStory (B4G4R4A4 emulation, #21).
- TMS MapleStory on older Intel Macs with NVIDIA Kepler GPUs (MoltenVK MSL cap, engine #11).
- MapleStory launch: Wine bugs [59926](https://bugs.winehq.org/show_bug.cgi?id=59926) and [59927](https://bugs.winehq.org/show_bug.cgi?id=59927), from GE-Proton (engine #12).
- BlueCG HD colored stripes with cnc-ddraw (#19).
- Windowed DirectDraw black screen (upstream Wine `b5ab3b15` backport, engine #2); Dock-minimized window restore (engine #10); native fullscreen ordering (engine #6).
- Umamusume: Pretty Derby blank login background: GStreamer now finds its H.264 decoder from the installed engine (#13).
- Interrupted environment setup no longer needs a reboot; a damaged record no longer makes Cyder read-only.
- With GPTK installed, every launch took exclusive control of all environments (trailing-slash path mismatch), so games started one at a time.
- Apple Command Line Tools are no longer needed.

### Removed
- DXVK 2: not shipped until it passes game testing.

## [0.13.2] - 2026-08-26

Engine `CX26.3.0-W11-Cyder012`. [Notes](docs/releases/v0.13.2.md).

### Fixed
- Engine upgrades update the shared environment in place instead of rebuilding it.

### Added
- MoltenVK version preference for DXVK.

## [0.13.1] - 2026-08-26

Engine `CX26.3.0-W11-Cyder012`. [Notes](docs/releases/v0.13.1.md).

### Added
- Engine Cyder012 with two MoltenVK versions (1.4.2 and 1.2.10).
- Informed-consent Rosetta installation on Apple Silicon.

### Fixed
- Engine version label display and environment preparation.

## [0.13.0]

Engine `CX26.3.0-W11-Cyder011`. [Notes](docs/releases/v0.13.0.md).

### Changed
- Faster first launch; Wine Mono and Gecko are no longer pre-installed.

### Added
- Opening `.msi`, `.bat`/`.cmd`, `.lnk` and `.reg` files directly.

Older releases: see the release table in [`docs/README.md`](docs/README.md).

[Unreleased]: https://github.com/dspp779/CyderBits/compare/claude/release-0.14.1...HEAD
[0.14.1]: https://github.com/dspp779/CyderBits/compare/v0.14.0...claude/release-0.14.1
[0.14.0]: https://github.com/dspp779/CyderBits/compare/v0.13.2...v0.14.0
[0.13.2]: https://github.com/dspp779/CyderBits/compare/v0.13.1...v0.13.2
[0.13.1]: https://github.com/dspp779/CyderBits/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/dspp779/CyderBits/releases/tag/v0.13.0
