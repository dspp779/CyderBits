# Testing BlueCG

BlueCG (BlueCrossgateNew／水藍魔力) is the project's DirectDraw PE32 test game.
Use it for anything that touches DirectDraw, cnc-ddraw, window resize/scaling,
Retina/DPI, CP950 text or multi-instance launches. General rules are in
[development-testing.md](../../development-testing.md) and the
`wine-game-compat-testing` skill; results and history are in [README.md](README.md).

## Facts to rely on

| Item | Value |
|---|---|
| Launch chain | `BlueLauncher.exe` (.NET, needs wine-mono) → `bluecg.exe` |
| Architecture / graphics | PE32 i386, DirectDraw (WineD3D or cnc-ddraw; never DXVK/DXMT) |
| Locale | Traditional Chinese, CP950 |
| Game arguments | `updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:1 GAHD` |
| Game's own DLL | `BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll` |
| Install on the development Mac | `~/Games/bluecg` (not in the repo; `BlueCrossgateNew/` is ignored) |

The launcher PID is not the game PID. Confirm `bluecg.exe` by window title and
PID before measuring or clicking.

## Offline tests (no game needed)

```bash
bash tests/run.sh bluecg cnc directdraw
```

This covers the run/verify scripts in dry-run mode, the benchmark and evidence
tools, and the per-game cnc-ddraw launch contract and options UI.

## Route A: through Cyder.app (product behaviour)

Use this for app-layer changes: game options, cnc-ddraw switch, launch
preparation, multi-instance.

1. Build a Developer ID signed test build (an ad-hoc build cannot launch games;
   see the signing table in the development guide). The engine must declare
   `native-ddraw-path-v1` (Cyder013 or later) for cnc-ddraw.
2. Open the build, add or select `BlueLauncher.exe` in the library.
3. For cnc-ddraw: 遊戲選項 → 顯示 → turn the cnc-ddraw switch on; the scaling
   filter and frame-limit controls enable only then. Graphics backend stays
   預設 or WineD3D. In the launcher choose HD[1] (961 × 721, 32-bit); the 16-bit
   window mode produces colour stripes with cnc-ddraw.
4. Launch and check, in this order, stopping at the first failure:
   - launcher window appears; game window appears after 開始遊戲;
   - text renders in Traditional Chinese, no stripes or wrong colours;
   - resize and maximize keep the picture (no black screen), scaling is smooth
     with Bilinear/Bicubic/Lanczos and blocky with Nearest;
   - minimize/restore, then exit through the game's own menu;
   - second and third instance from the same launcher start and keep their own
     DirectDraw settings.
5. Read `~/Library/Application Support/Cyder/Logs/last-launch.log`: no
   `diagnostic event=error`, and the loaded `ddraw` is the one expected
   (native cnc-ddraw path when the switch is on, builtin otherwise).

`BlueLauncher.exe` and `bluecg.exe` are separate library entries with separate
DirectDraw preferences; the child inherits the entry that launched it. Turning
the switch on changes the developer's real per-game settings, so restore it
afterwards unless asked to keep it. Details: [per-game DirectDraw](../../per-game-directdraw.zh-TW.md).

## Route B: straight on an engine (engine or renderer work)

Use this to compare engines or renderers without the app in the way. Work on a
**copy** of the game with its own prefix: `scripts/run-bluecg.sh` writes into
the game folder (`--ddraw-source official` copies `DDRAW.dll` to `ddraw.dll`,
`builtin` deletes it; `local` leaves it alone).

```bash
bash scripts/run-bluecg.sh --prefix /path/to/test-prefix --game-dir /path/to/bluecg-copy --wine-install "$HOME/.cyder/runtime/Engines/wine-x86_64" --ddraw-source local --dry-run
```

Drop `--dry-run` to launch; add `--direct` to skip the launcher. `--soft3d`
changes two things at once (`3Ddevice:0` and no `GAHD`), so do not use it as a
renderer A/B. Renderer comparisons, CPU, frame-time and power measurements
follow [benchmark-protocol.zh-TW.md](benchmark-protocol.zh-TW.md) with
`scripts/bluecg-benchmark.py`; never report an FPS or power ranking from runs
with different scenes, window sizes or other games running.

Stop only the test prefix's wineserver (`WINEPREFIX=… wineserver -k`). Never
kill Wine system-wide: other bottles share the machine.

## What must not be claimed

- "cnc-ddraw works" from the switch being on: confirm the loaded module.
- Native fullscreen Space results from borderless-fullscreen results
  ([engine #4](https://github.com/dspp779/cyder-wine-engine/issues/4)).
- Performance or power improvements without the protocol's A/B/A runs.

Logging in to the game, anything that costs in-game currency, and public
issue/PR comments need the user's explicit go-ahead.
