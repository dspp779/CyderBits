<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**Run legacy Windows games on Mac — Cyder 0.14.0 uses DirectDraw and GDI as its validation baseline, with selectable graphics backends.**

The validated path remains classic 2D Win32 graphics: **DirectDraw → Wine wined3d/OpenGL** and GDI. Cyder 0.14.0 uses the `CX26.3.0-W11-Cyder013` engine (dual MoltenVK); DXVK and DXMT are delivered as separate graphics payloads, while D3DMetal is available through GPTK. Actual compatibility still depends on the game, macOS version, and selected backend.

This repo (CyderBits) is currently the **application layer**: the Cyder launcher, game library, settings, CompatDB, and packager. The Wine engine that actually runs Windows `.exe` files lives in [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine).

This project ships two tools: **Cyder** — a one-click `.exe` launcher — and **CyderBits** — a packager that wraps `.exe` files as double-clickable macOS `.app` bundles.

**Languages:** [English](README.md) · [繁體中文](README.zh-TW.md)

## Cyder (launcher)

| | |
|---|---|
| **What** | Open any Windows `.exe` with one shared Wine prefix |
| **Engine** | Shared Wine under `~/.cyder/runtime/Engines/` (kept free of spaces) |
| **Docs** | [docs/cyder.md](docs/cyder.md) |

```bash
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

## CyderBits (packager)

| | |
|---|---|
| **What** | Pick a Windows `.exe` → get a macOS game `.app` |
| **Prefix** | Per-game bottle under `~/Library/Application Support/Cyder/Bottles/` (Phase 1) |
| **Docs** | [docs/cyderbits.md](docs/cyderbits.md) |

```bash
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
```

## Validation game

Development and smoke tests target **[BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)** (魔力寶貝), a DirectDraw PE32 title. Place the game files locally as `BlueCrossgateNew/` (not in git).

```bash
bash scripts/run-bluecg.sh
```

## 🎮 Tested Games Compatibility

Below is a summary of tested games on Cyder / CyderBits. For detailed configurations, launch parameters, and workarounds, see the **[📋 Game Compatibility Matrix](docs/games/compatibility-matrix.md)**.

| Category | Game | Status | Key Notes / Workarounds |
|:---:|:---|:---:|:---|
| **Single-player** | Age of Empires II (3.8) | ⚠️ Playable | Micro-stutters every 5 seconds (known Wine/macOS issue) |
| **Single-player** | Richman 4 (大富翁4) | 🟡 Needs ddraw | Black screen by default; requires `cnc-ddraw` to render properly |
| **Single-player** | Pikachu Volleyball | 🟡 Special condition | Disable MSync recommended; CrossOver requires "Save Log" enabled |
| **Single-player** | Mega Man X3 / X4 | ⚠️ Non-fatal error | Shows DirectX init error on boot; dismiss prompt to play normally |
| **Single-player** | Mega Man X5 | ⚠️ Display issue | Playable, but window stays aligned/scaled to top-left |
| **Single-player** | Metal Slug | 🟢 Playable | Disable Retina mode |
| **Single-player** | Diablo II | 🟢 Playable | Disable Retina mode |
| **Single-player** | Warcraft III | 🟢 Playable | Add `-nativefullscr` launch argument for native resolution |
| **Single-player** | Little Fighter 2 (1.9c) | 🟢 Playable | Works directly out of the box |
| **Single-player** | Little Fighter 2 (2.0a) | 🟡 Winetricks deps | Requires `vcrun2005`, `wmp9`, `quartz`, `devenum`, `vb6run` via winetricks |
| **Online** | BlueCG (水藍魔力) | 🟢 Playable | Project baseline validation (DirectDraw / GDI) |
| **Online** | MapleStory (新楓之谷) | 🟡 Partially validated | Requires the MapleStory Launcher, [CitrusGate](https://github.com/dspp779/CitrusGate), and a valid OTP; CX26 still needs map-level validation |
| **Online** | MapleStory Classic | 🟡 Partially validated | Requires [CitrusGate](https://github.com/dspp779/CitrusGate); QDO workaround and background-process cleanup remain limited |
| **Online** | Crazy Arcade (爆爆王) | 🟡 Historical validation | Service availability and current-version compatibility have not been revalidated on current releases |

## Graphics backend status

| Backend | Project status | Notes |
|---|---|---|
| DirectDraw / GDI | **Supported and validated** | BlueCG uses DirectDraw; the default path is wined3d/OpenGL. GDI is a compatibility fallback. |
| wined3d / OpenGL | **Active default** | BlueCG's validated engine includes the tested `winemac.drv` same-view backing fix for Retina/DPI resize. |
| Vulkan / MoltenVK | **Provided by the engine** | Dual-variant: wait-poll shim + `.real` → `1.4.2` / `1.2.10`; Preferences can switch; macOS &lt; 12 forces 1.2.10. Not the primary BlueCG path. |
| DXVK | **Integrated as a runtime payload** | DXVK is delivered under `Resources/graphics/` and loaded through CompatDB builtin + prepend; DXVK 2 is still deferred. |
| dxmt | **Integrated as a runtime payload** | DXMT is delivered as a separate Cyder payload and requires macOS 15+; MapleStory.exe and Maplestory_Classic.exe prefer it automatically on macOS 15+. |
| D3DMetal | **Product backend** | Available through GPTK / Apple D3DMetal on macOS 14+ with a usable GPTK; game compatibility must be validated per title. |

See [Wine configure and graphics options](docs/wine-configure-options.md) for build choices and limitations.

## Wine engine

The runtime that actually executes `.exe` files is [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine). Wine is built from the **CrossOver open-source release** (see [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)). Build, patch, sign and pack the engine in that repo; `Cyder.app` bundles the engine release pinned in `config/cyder-engine-manifest.json`. See [docs/cyder-wine-engine-project.md](docs/cyder-wine-engine-project.md).

## Requirements

- **Support policy:** Cyder **0.14** (engine **Cyder013**) is the **last release that supports macOS 10.15 and 11**. Later releases require **macOS 12+**.
- **Cyder.app:** macOS 10.15+ (`LSMinimumSystemVersion`); Game Library / settings UI on **11+** (10.15 performs first-run setup in a visible Terminal, then uses Bash file selection / launch)
- **Game location:** `~/Games` is recommended; macOS may allow the selected EXE but deny sibling DLLs under Documents, Desktop, Downloads, cloud storage, or external volumes
- **Development / build:** macOS 12+ recommended (13+ for day-to-day work)
- Apple Silicon + Rosetta 2 (Wine is an **x86_64** build; Rosetta required on Apple Silicon from macOS 11+)
- Several GB disk for Wine sources, `.brew-x86`, and build outputs (most paths are `.gitignore`d)

## Quick start

### 1. Get a Wine engine

`Cyder.app` needs the pinned engine archive named in `config/cyder-engine-archive.txt`. Build and pack it in a sibling checkout of [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine) (first build is slow; follow its from-scratch guide), or pass an existing archive with `--engine-archive`.

### 2. Build and open Cyder

```bash
bash scripts/release-cyder.sh --channel test --out-dir "${TMPDIR:-/tmp}/cyder-test-build"
open "${TMPDIR:-/tmp}/cyder-test-build/Cyder.app"
```

This ad-hoc build shows windows and settings. Launching a game needs a Developer ID signature; see [docs/development-testing.md](docs/development-testing.md).

### 3. Validate with BlueCG

```bash
bash scripts/run-bluecg.sh
bash scripts/enable-mac-retina-hires.sh   # optional Retina + 200% DPI
```

Step-by-step checks: [docs/games/bluecg/testing.md](docs/games/bluecg/testing.md).

### 4. Wrap any EXE as a game app

```bash
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
# or: python3 scripts/cyder_create_game_app.py --gui
```

## Implemented workarounds

- [Chinese font default](docs/workarounds/font-default.md) — maps common Windows CJK fonts to Songti TC by default.
- [RetinaMode window setup](docs/workarounds/retina-mode.md) — RetinaMode + DPI script and its resize caveats.
- [BlueCG A6 resize fix](docs/workarounds/bluecg-a6-resize.md) — tested same-view backing sync for resize, Alt+Enter, and minimize/restore.
- [Pikachu Volleyball compatibility](docs/games/pikachu-volleyball/README.md) — use a no-space runtime path with MSync and ESync disabled.

## Repository layout

```text
├── scripts/                    # Cyder.app sources (Bash + Swift), build and release scripts
├── tests/                      # Offline tests; run with tests/run.sh
├── compatdb/                   # Per-game compatibility rules and compiled database
├── recipes/                    # Game app recipes for the CyderBits packager
├── config/                     # App version, pinned engine manifest, entitlements
├── patches/                    # Graphics and reference patches
├── vendor/cnc-ddraw/           # Bundled cnc-ddraw
├── docs/                       # Guides (see docs/README.md)
├── .agents/skills/             # Step-by-step guides for AI agents (entry: AGENTS.md)
├── logo/                       # App icon and README logo
├── build/ install/ .brew-x86/ tools/archives/   # Links into the cyder-wine-engine checkout (.gitignore)
└── BlueCrossgateNew/           # BlueCG game + prefix (.gitignore)
```

## Tests

```bash
bash tests/run.sh <word>   # tests whose name contains <word>
bash tests/run.sh          # whole suite, about 12 minutes
```

Which check fits which change, test builds, signing and real-app checks: [docs/development-testing.md](docs/development-testing.md).

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — changes per version
- [Cyder 0.14.0 release notes](docs/releases/v0.14.0.en.md) — Cyder013 engine, quit without stopping games, per-game cnc-ddraw, DXVK black-texture fix; last release for macOS 10.15 and 11
- [docs/README.md](docs/README.md) — index of all guides and earlier release notes
- [docs/cyder.md](docs/cyder.md) — Cyder launcher
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits packager
- [docs/games/compatibility-matrix.md](docs/games/compatibility-matrix.md) — tested games
- [docs/development-testing.md](docs/development-testing.md) — tests, test builds, real-app and game checks
- [docs/release-pipeline.zh-TW.md](docs/release-pipeline.zh-TW.md) — signing, notarizing and publishing a release
- [docs/cyder-wine-engine-project.md](docs/cyder-wine-engine-project.md) — application layer vs [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)
- [docs/bluecg.md](docs/bluecg.md) — BlueCG workflow
- [docs/scripts.md](docs/scripts.md) — script reference
- [AGENTS.md](AGENTS.md) — rules and skills for AI agents

## Sources and licensing

Wine sources come from the [CrossOver open-source release](https://www.codeweavers.com/crossover/source). Game files and large binaries are not in git; obtain them separately (e.g. [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)).
