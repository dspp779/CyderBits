<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**Run legacy Windows games on Mac — DirectDraw & GDI first.**

The validated path is classic 2D Win32 graphics: **DirectDraw → Wine wined3d/OpenGL** and GDI. The current packaged `CX26.3.0-W11-Cyder004` engine also contains an x86_64 **MoltenVK** runtime for Wine Vulkan (repacking defaults to `VULKAN_MODE=with` + `VULKAN_SOURCE=existing`), but BlueCG does not use Vulkan, DXVK, dxmt, or D3DMetal.

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

## Graphics backend status

| Backend | Project status | Notes |
|---|---|---|
| DirectDraw / GDI | **Supported and validated** | BlueCG uses DirectDraw; the default path is wined3d/OpenGL. GDI is a compatibility fallback. |
| wined3d / OpenGL | **Active default** | BlueCG's validated engine includes the tested `winemac.drv` same-view backing fix for Retina/DPI resize. |
| Vulkan / MoltenVK | **Included in the current packaged engine** | `libMoltenVK.dylib` is bundled for x86_64 Wine Vulkan support (macOS 10.15 minos); it is not the BlueCG rendering path. `pack-engine-artifact.sh` keeps MoltenVK by default; fresh source builds may use `--without-vulkan`. |
| DXVK | **Not integrated** | No DXVK runtime or game validation is shipped by this repository. |
| dxmt | **Not integrated** | No dxmt build, packaging, or compatibility result is maintained here. |
| D3DMetal | **Not a product backend** | Only referenced by historical source experiments; it is not wired or validated as a Cyder runtime path. |

See [Wine configure and graphics options](docs/wine-configure-options.md) for build choices and limitations.

## Wine sources

Wine is built from the **CrossOver open-source release** — place archives in `tools/archives/` (see [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)); builds extract into `build/cx25/` or `build/cx26/`.

```bash
bash scripts/build-wine.sh --cx 26
bash scripts/build-wine.sh --cx 25
bash scripts/sign-wine.sh
```

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

## Requirements

- **Cyder.app:** macOS 10.15+ (`LSMinimumSystemVersion`); Game Library / settings UI on **12+** (10.15–11.x uses bash + osascript legacy UI)
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
│   ├── wine-cx25-x86_64/       # CX25 engine (.gitignore)
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

- [Cyder 0.6.0 release notes](docs/releases/v0.6.0.en.md) — CX26.3 engine, macOS 10.15 runtime, Winetricks, dynamic argv
- [docs/README.md](docs/README.md) — index
- [docs/cyder.md](docs/cyder.md) — Cyder launcher
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits packager
- [docs/bluecg.md](docs/bluecg.md) — BlueCG workflow
- [docs/scripts.md](docs/scripts.md) — script reference
- [docs/superpowers/](docs/superpowers/) — design specs

## Sources and licensing

Wine sources come from the [CrossOver open-source release](https://www.codeweavers.com/crossover/source). Game files and large binaries are not in git; obtain them separately (e.g. [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)).
