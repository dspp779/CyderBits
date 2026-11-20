# Changelog

Notable changes to Cyder. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). Each entry links to the full
release notes in [`docs/releases/`](docs/releases/); the engine column refers to
[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine).

## [Unreleased]

## [0.15.0] - 2026-11-20

Engine `CX26.3.0-W11-Cyder014`; requires macOS 12 or later.
Notes: [繁中](docs/releases/v0.15.0.md) · [English](docs/releases/v0.15.0.en.md).

### Added
- Steam games opened directly from `steamapps/common/` get their Steam App ID from
  Steam's `appmanifest`.
- Cities: Skylines II uses DXMT automatically while its graphics setting is "default" (#10).
- MECCHA CHAMELEON uses DXMT and `-dx11` automatically while its graphics setting is "default"
  (DXVK leaves the main-menu scene black). Where DXMT cannot run it uses D3DMetal, else DXVK.
- MapleStory WZ read-ahead (engine Cyder014), merged with the WZ cache into one setting,
  "MapleStory WZ 檔案讀取最佳化", on by default.

### Fixed
- A fullscreen game that was force-quit no longer shows "程式在顯示視窗前就結束了"
  (`CYD-WIN-002`), and a fullscreen launch no longer holds the next launch for 30 s:
  Cyder now sees Wine's raised fullscreen window levels.
- An error dialog no longer holds later launches until it is closed, and repeated
  requests for the same program (double-clicks) start it once instead of in a burst.
- A launcher that starts the game and exits with an error code no longer shows
  `CYD-WIN-002` while the game is still opening.

### Changed
- DXMT is used only on a GPU with Metal GPU Family Mac 2. On older Intel GPUs MapleStory
  falls back to DXVK, the DXMT setting is disabled, and Cities: Skylines II stops before
  launch with `CYD-GFX-002` instead of crashing.
- Engine `CX26.3.0-W11-Cyder014`: minOS-safe build (engine #14), wineserver no longer
  crashes when a program is killed (engine #16), Unity Mono last error fix (engine #17).

### Removed
- Support for macOS 10.15 and 11. Releases after 0.14 require macOS 12 or later.
- MoltenVK 1.2.10 and the MoltenVK version setting; DXVK uses MoltenVK 1.4.2.

## [0.14.1] - 2026-11-15

Engine `CX26.3.0-W11-Cyder013`, rebuilt for older macOS compatibility.
Notes: [繁中](docs/releases/v0.14.1.md) · [English](docs/releases/v0.14.1.en.md).

### Fixed
- Updating the Windows environment crashed on older macOS such as 15.8 (engine #14).
- Slow launches, and a long wait when opening a second program while another was starting.
- The "正在啟動程式…" window hidden behind other apps, left open after a crash, and the program not coming to the front.
- A missing Windows component reported only as an exit code.
- Reopening a game right after it exited sometimes failed.
- The status stuck at "正在確認執行狀態…" after a restart.
- Background processes left running after a program exited.
- DXVK not updating with the app.

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

[Unreleased]: https://github.com/dspp779/CyderBits/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/dspp779/CyderBits/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/dspp779/CyderBits/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/dspp779/CyderBits/compare/v0.13.2...v0.14.0
[0.13.2]: https://github.com/dspp779/CyderBits/compare/v0.13.1...v0.13.2
[0.13.1]: https://github.com/dspp779/CyderBits/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/dspp779/CyderBits/releases/tag/v0.13.0
