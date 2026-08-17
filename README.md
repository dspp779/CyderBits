<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**Run legacy Windows games on Mac — Cyder 0.11.1 uses DirectDraw and GDI as its validation baseline, with selectable graphics backends.**

The validated path remains classic 2D Win32 graphics: **DirectDraw → Wine wined3d/OpenGL** and GDI. Cyder 0.11.1 uses the `CX26.3.0-W11-Cyder011` engine; DXVK and DXMT are delivered as separate graphics payloads, while D3DMetal is available through GPTK. Actual compatibility still depends on the game, macOS version, and selected backend.

CyderBits builds CrossOver-based Wine on Apple Silicon and ships two tools: **Cyder** — a one-click `.exe` launcher — and **CyderBits** — a packager that wraps `.exe` files as double-clickable macOS `.app` bundles.

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
| **Online** | Crazy Arcade (爆爆王) | 🟡 Historical validation | Service availability and current-version compatibility were not revalidated for Cyder 0.10.1 |

## Graphics backend status

| Backend | Project status | Notes |
|---|---|---|
| DirectDraw / GDI | **Supported and validated** | BlueCG uses DirectDraw; the default path is wined3d/OpenGL. GDI is a compatibility fallback. |
| wined3d / OpenGL | **Active default** | BlueCG's validated engine includes the tested `winemac.drv` same-view backing fix for Retina/DPI resize. |
| Vulkan / MoltenVK | **Provided by the Cyder011 engine** | `libMoltenVK.dylib` is bundled for x86_64 Wine Vulkan support (macOS 10.15 minos); Cyder011 does not use the obsolete `libMoltenVK.real.dylib` shim pair. It is not the primary BlueCG rendering path. |
| DXVK | **Integrated as a runtime payload** | DXVK is delivered under `Resources/graphics/` and loaded through CompatDB builtin + prepend; DXVK 2 is still deferred. |
| dxmt | **Integrated as a runtime payload** | DXMT is delivered as a separate Cyder payload and requires macOS 15+; MapleStory.exe and Maplestory_Classic.exe prefer it automatically on macOS 15+. |
| D3DMetal | **Product backend** | Available through GPTK / Apple D3DMetal on macOS 14+ with a usable GPTK; game compatibility must be validated per title. |

See [Wine configure and graphics options](docs/wine-configure-options.md) for build choices and limitations.

## Wine sources

Wine is built from the **CrossOver open-source release** — place archives in `tools/archives/` (see [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)); builds extract into `build/cx26/`.

```bash
bash scripts/build-wine.sh --cx 26
bash scripts/sign-wine.sh
```

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

## Requirements

- **Cyder.app:** macOS 10.15+ (`LSMinimumSystemVersion`); Game Library / settings UI on **11+** (10.15 performs first-run setup in a visible Terminal, then uses Bash file selection / launch)
- **Game location:** `~/Games` is recommended; macOS may allow the selected EXE but deny sibling DLLs under Documents, Desktop, Downloads, cloud storage, or external volumes
- **Development / build:** macOS 12+ recommended (13+ for day-to-day work)
- Apple Silicon + Rosetta 2 (Wine is an **x86_64** build; Rosetta required on Apple Silicon from macOS 11+)
- Several GB disk for Wine sources, `.brew-x86`, and build outputs (most paths are `.gitignore`d)

## Quick start

### 1. Build Wine (first time; slow)

```bash
bash scripts/build-wine.sh --cx 26 --install-deps
bash scripts/build-wine.sh --cx 26
bash scripts/sign-wine.sh
```

### 2. Validate with BlueCG

```bash
bash scripts/run-bluecg.sh
bash scripts/enable-mac-retina-hires.sh   # optional Retina + 200% DPI
```

## Implemented workarounds

- [Chinese font default](docs/workarounds/font-default.md) — maps common Windows CJK fonts to Songti TC by default.
- [RetinaMode window setup](docs/workarounds/retina-mode.md) — RetinaMode + DPI script and its resize caveats.
- [BlueCG A6 resize fix](docs/workarounds/bluecg-a6-resize.md) — tested same-view backing sync for resize, Alt+Enter, and minimize/restore.
- [Pikachu Volleyball compatibility](docs/games/pikachu-volleyball/README.md) — use a no-space runtime path with MSync and ESync disabled.

### 3. Run or wrap any EXE

```bash
# Cyder launcher — open .exe directly
bash scripts/create-cyder-app.sh
open dist/Cyder.app

# CyderBits packager — wrap .exe as a game .app
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
# or: python3 scripts/cyder_create_game_app.py --gui
```

## Repository layout

```text
├── logo/                       # cyderbits.png (app icon), cyderbits-transparent.png (README)
├── config/entitlements.plist   # Wine JIT / dyld signing entitlements
├── patches/                    # Optional source patches
├── scripts/                    # Build, run, packaging
├── tests/                      # Script smoke tests
├── docs/                       # Guides (see docs/README.md)
├── tools/
│   ├── archives/               # CrossOver + llvm-mingw archives (.gitignore)
│   └── libarchive/             # GnuWin bsdtar payload
├── build/                      # Extracted sources + llvm-mingw (.gitignore)
├── .brew-x86/                  # Project-local x86_64 Homebrew (.gitignore)
├── install/
│   └── wine-cx26-x86_64/       # CX26 engine (.gitignore)
└── BlueCrossgateNew/           # BlueCG game + prefix (.gitignore)
```

## Tests

```bash
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
bash tests/test-build-wine.sh
bash tests/test-sign-wine.sh
bash tests/test-run-bluecg.sh
bash tests/test-verify-bluecg.sh
```

## Documentation

- [Cyder 0.11.1 release notes](docs/releases/v0.11.1.md) — gamaniagames:// URI handler, open -n file URLs, and URI cold-start Preferences skip
- [Cyder 0.10.1 test release notes](docs/releases/v0.10.1.md) — forced-stop liquid animation, MapleStory WZ adaptive cache, release tooling, tests, and documentation updates
- [Cyder 0.10.0 release notes](docs/releases/v0.10.0.md) — Cyder010 engine, graphics payloads, session lifecycle, and diagnostics
- [Cyder 0.7.0 release notes](docs/releases/v0.7.0.en.md) — CrossOver bottle isolation, cabextract, new icon, MapleStory OEM flavor
- [Cyder 0.6.0 release notes](docs/releases/v0.6.0.en.md) — CX26.3 engine, macOS 10.15 runtime, Winetricks, dynamic argv
- [docs/README.md](docs/README.md) — index
- [docs/cyder.md](docs/cyder.md) — Cyder launcher
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits packager
- [docs/bluecg.md](docs/bluecg.md) — BlueCG workflow
- [docs/scripts.md](docs/scripts.md) — script reference
- [docs/superpowers/](docs/superpowers/) — design specs

## Sources and licensing

Wine sources come from the [CrossOver open-source release](https://www.codeweavers.com/crossover/source). Game files and large binaries are not in git; obtain them separately (e.g. [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)).
