# Cyder: program control for players

Date: 2026-11-20. Status: design, not implemented. Builds on the 0.15.0
launch detection ([launch-detection.md](../../launch-detection.md)) and the
LaunchGroup menu ([2026-08-19 design](2026-08-19-launchgroup-menu-bar-design.md)).
No engine change is required for anything marked phase 1 or 2.

## Goal

Give a player a sense of control over what they opened in Cyder. A player
asks three things:

1. Is my game still running?
2. How do I get back to it?
3. How do I close it, especially when it is stuck, hidden or fullscreen?

Process trees and PIDs (Windows or macOS) are not shown to the player. What
matters is what is running, what has ended, and how it ended.

## Decisions (2026-11-20)

- **強制結束 always asks for confirmation**, like macOS Force Quit.
- **Ending a program that others may depend on always warns first** (Steam
  while a Steam game runs). There is no "don't ask again".
- Wine's own background programs are never shown
  (`ProcessRecord.wineHelpers`, see launch-detection.md).

## What the player sees

One row per thing the player opened. Name: the game library title when there
is one, else the `.exe` name. A launcher and the game it starts are one row,
named after the game.

| Status | Meaning |
|---|---|
| 正在啟動… | Launched, no window yet |
| 執行中 | Has a window |
| 在背景執行 | Running with no window: Steam logged in, a launcher, a tray program |
| 沒有回應 | 結束 was requested and the program is still running after the grace period |
| 正在結束… | The player asked it to close |
| 已結束 / 意外結束 / 已由你結束 | Shown briefly after the end, then the row is removed |

Background programs a game started and left behind (a launcher, Steam, a crash
reporter) appear as their own 在背景執行 rows so they can be ended.

## Actions

| Action | Behaviour | Confirmation |
|---|---|---|
| 顯示視窗 | Bring the program's window to the front (exists) | None |
| 結束 | Polite close, like the window's ✕: the program can save and exit | None, except the dependency warning below |
| 強制結束 | Kill the program's processes immediately | Always: 「強制結束 X？未儲存的進度會遺失。」 [強制結束] [取消] |
| 結束所有 Windows 程式… | Today's 停止 Windows 環境, under 進階 | Always (exists) |

**結束 escalates.** If the program is still running 5 s after 結束, the row
shows 沒有回應 and offers 強制結束 (still confirmed). The player never has to
judge up front whether a game is frozen.

**Dependency warning.** Before 結束 or 強制結束 on a program that other running
programs may need, always ask:
「Steam 結束後，仍在執行的遊戲可能無法正常運作或存檔。仍要結束 Steam？」
[結束] [取消]. Phase 1 knows one such program, Steam (`steam.exe` with
`steamwebhelper.exe` and `steamservice.exe` as its parts); the list lives next
to the CompatDB rules so more can be added without code changes.

## Where it appears

**Menu bar (primary).** Reachable even when a fullscreen game is frozen.

```
Cyder
├ MECCHA CHAMELEON      執行中     ▸ 顯示視窗 / 結束 / 強制結束…
├ Steam                 在背景執行 ▸ 結束… / 強制結束…
├ ─────
├ 遊戲庫… / 偏好設定…
└ 進階 ▸ 工作管理員… / 結束所有 Windows 程式…
```

**Game library.** A running game shows a 執行中 badge; its 開啟 button
becomes 顯示 (brings the window forward instead of launching a second copy,
which 0.15.0 would drop anyway), with 結束 next to it.

**Notifications, only when something needs attention.**

- 「MECCHA CHAMELEON 意外結束」 with 查看紀錄 (phase 2).
- 「Steam 仍在背景執行」 after the last game it served ends, with 結束 (phase 2).

**Quitting Cyder** keeps games running (0.14 behaviour). Reopening Cyder shows
them again.

## How each piece works without an engine change

| Feature | Mechanism | Confidence |
|---|---|---|
| Running / background / ended | macOS process table plus window detection (exists) | High |
| Hiding Wine background programs | Helper list (0.15.0) | High |
| 結束 | Press the window's close button through Accessibility (`AXCloseButton`); Cyder already requests this permission for window actions. Without the permission or without a window: run Wine's `taskkill /im <image>` in the program's environment, which sends the same close request. Only while the program is alive, so no wineserver is started (see "Constraints") | High with Accessibility; medium for the fallback |
| 強制結束 | SIGKILL the program's macOS processes (the row's launch members). Safe since engine Cyder014: wineserver survives a killed client (engine #16; B2 tested on M4) | High |
| 意外結束, launched program | Its root exit status; Wine's crash dialog appearing | High |
| 意外結束, programs it started | macOS gives no exit status for reparented processes; only the crash dialog is visible | Partial |
| 沒有回應 detected directly | No public macOS API for a Wine window's responsiveness | Not supported; "still running after 結束" stands in |
| Launcher + game as one row, real names | Existing launch membership. Later: Wine's `+process` trace (phase 3) | Medium; better in phase 3 |

### Constraints from the 2026-11-20 pilot

- Any Wine program started when no wineserver is running starts one, with
  `services.exe` and its services. `WINESERVER` cannot prevent it. So a Wine
  helper (`taskkill`) may run only while macOS shows a program of that
  environment alive.
- Each Wine helper resets wineserver's 3 s shutdown timer. Run helpers on
  demand only (a user action), never on a timer.
- `WINEDEBUG=+process` adds about 67 lines/s during MECCHA CHAMELEON gameplay
  (mostly `NtQueryInformationProcess`); measure on more games before phase 3.

## Phases

1. **Phase 1:** menu rows with the statuses above; 結束 (Accessibility, then
   `taskkill /im`), 強制結束 with confirmation, 沒有回應 escalation; the
   dependency warning for Steam; library 顯示 / 結束 buttons and the 執行中 badge;
   leftover background rows.
2. **Phase 2:** 意外結束 and 「仍在背景執行」 notifications; 已結束 result shown
   briefly in the row.
3. **Phase 3:** `+process` trace for names and launcher/child grouping, after
   measuring its log volume on more games.

## Tests and checks (phase 1)

- Status words per state: unit tests over lifecycle snapshots
  (`tests/test-cyder-lifecycle-*`).
- 強制結束 and the dependency warning always show their dialog; 結束 does not
  (except the warning); dialogs open through `presentLaunchDialog`-style
  run-loop blocks so they do not hold launches.
- 結束 escalation timing with a fake clock.
- `taskkill` runs only while a program of the environment is alive.
- On a real Mac: 結束 a windowed game (saves and exits), 強制結束 a frozen or
  fullscreen game from the menu bar, 結束 Steam while a game runs (warning
  shown), and the library button change. Intel and Apple Silicon.

## Not in scope

- Showing PIDs, process trees or Windows services to players.
- Per-program CPU or memory figures.
- Restarting a program automatically after it ends.
