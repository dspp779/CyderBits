# Cities: Skylines II — testing

Agent and developer steps for testing CS2 (Steam app 949230) in Cyder. Results
and background: [support assessment](../cities-skylines-2-support-assessment.zh-TW.md).

## Requirements

- Engine with `cyder-ntdll-mono-gs-last-error.patch` (cyder-wine-engine PR #17).
  Without it the unmodified game stops at start-up with `IOException`.
- Windows Steam in the same bottle and engine, logged in, global graphics
  **not** DXVK (Steam then shows no window; see [Steam](../steam/README.md)).
- Game graphics DXMT (per-game setting, or `CYDER_GRAPHICS_BACKEND=dxmt` for a
  direct Wine run).

## Start the game

Start `Cities2.exe` directly, not with Steam's Play button (that installs and
runs the Paradox Launcher). The Cyder launcher sets
`SteamAppId`/`SteamGameId`/`SteamOverlayGameId=949230`; for a direct Wine run,
set them yourself. Without them the game logs
`platform service integration failed` and then throws `NullReferenceException`.
`steam_appid.txt` is not needed.

For automated clicking add `-screen-fullscreen 0`: the default exclusive
fullscreen window is on layer 26 and `guarded-click` refuses it on purpose.

## Driving the UI

- The game UI (Coherent Gameface) often ignores a click whose pointer arrived
  100 ms earlier. Send one `guarded-key ... shift --send` right before a click,
  or click a button twice when a double activation is harmless.
- `return` activates the default button (select map, start game, dialogs);
  `escape` opens the pause menu.
- First start shows the Paradox user agreement and privacy policy. Accepting
  them is the user's decision.

## Checks

| Step | Pass |
|---|---|
| Start | `SceneFlow.log`: `MainMenu reached`; no `ERROR`/`FATAL` in `Logs/*.log` |
| New game | Standard mode, any map; `Loading completed` |
| Save | Pause menu → 儲存遊戲 → 儲存; a new `.cok` in `Saves/<Steam ID>/` |
| Reload | Restart, 繼續遊戲; `Loading mode Game with purpose LoadGame` |
| Run | Several minutes with no new errors |
| Exit | Pause menu → 退出 → 退出至桌面; `Cities2.exe` and `UnityCrashHandler64.exe` end, Steam keeps running |

Logs are in `C:\users\crossover\AppData\LocalLow\Colossal Order\Cities Skylines II\`
(`Player.log`, `Logs/*.log`). Do not copy the Steam ID from the save path into
public reports.
