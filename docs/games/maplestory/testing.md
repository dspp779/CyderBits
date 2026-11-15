# Testing TW MapleStory

How an agent logs in, plays and measures TW MapleStory (新楓之谷) on this Mac.
Follow the `wine-game-compat-testing` skill for the general rules; this page
adds the game-specific steps. Scripts are in
`.agents/skills/wine-game-compat-testing/scripts/`.

Learned in the first-hit stutter work (November 2026, issue #22,
[stutter-test-plan.md](stutter-test-plan.md)).

## Before starting

| Who | What |
|---|---|
| User | Signs in to the **Beanfun OTP** app (scans the QR code). Sessions expire; when the app shows the QR code again, ask the user to rescan. |
| User | Switches the Beanfun OTP app to **advanced mode** when the game is to be started from the command line; it then shows the launch arguments. |
| User | Parks the test character somewhere safe (for the first-hit test: a pillar where monsters cannot reach it, next to spawning monsters). |
| User | Grants Screen Recording and Accessibility to the app that runs the agent's commands (System Settings → Privacy & Security). The agent never edits TCC. |
| User | Runs `sudo purge` when a cold page cache is needed; it needs the admin password. |
| Agent | Compiles the control tools once (below). |
| Agent | Checks that no other MapleStory or Cyder test build is running. |

```bash
S="${TMPDIR:-/tmp}"; K=.agents/skills/wine-game-compat-testing/scripts
swiftc -O -o "$S/gkey" "$K/guarded-key.swift"
swiftc -O -o "$S/gclick" "$K/guarded-click.swift"
swiftc -O -o "$S/wine-windows" "$K/wine-windows.swift"
```

`swift script.swift` compiles on every call (1–2 s); compiled binaries respond at once,
which matters when a key must land at a known moment.

## Start the game

Each launch needs a **fresh OTP**: an OTP works once. In the app, press 立即更新
or 取得 OTP before every launch.

**Normal route (tests Cyder too):** the user presses 啟動遊戲 in the Beanfun OTP
app. Cyder opens `MapleStory.exe` with the account and OTP as arguments.

**Command-line route (tests the engine alone):** use it when the Cyder app is
being changed, or to set a backend, an engine copy or the I/O trace per run.
The account ID is the `ServiceAccountID` (`T9…`) shown in advanced mode, not the
display name; with a display name the game starts and then the server says the
account is not registered.

```bash
MS_ACCOUNT_ID=T9… MS_OTP=… "$K/maplestory-launch.sh" \
  --game-dir ~/games/tms --backend dxvk          # dxmt | d3dmetal | wined3d
# prints:  log=…  pid=… window_id=… title=MapleStory size=…  graphics backend=…
```

- The script passes the account ID and OTP to the game only. It never prints them
  or writes them to the log; `--dry-run` shows the command with both masked.
- The game's command line still holds the OTP while it runs. Do not paste `ps`
  output into notes, issues or chat.
- Check the `graphics backend=` line before measuring. An engine copy with
  relative `lib/dxvk` or `lib/dxmt` links silently falls back to wined3d.
- `--engine DIR` runs a test engine; the installed engine at
  `~/.cyder/runtime/Engines/wine-x86_64` is never replaced.
- `--io-trace` adds the engine's WZ I/O trace (see Inspect below).

## See the window

Wine windows have no bundle ID, so computer-use tools cannot grant or capture
them. Use the window ID instead:

```bash
"$S/wine-windows" | python3 -I -c 'import json,sys;[print(w["pid"],w["window_id"],w["title"],w["bounds"]) for w in json.load(sys.stdin)["windows"] if w["layer"]==0]'
screencapture -x -o -l <window_id> -t jpg shot.jpg && sips -Z 1366 shot.jpg --out shot-small.jpg
```

- Take the window ID again after login and after changing maps; a new window
  gets a new ID.
- Click and key coordinates are in window **points including the title bar**.
  Scale from the screenshot with `bounds.Width / image width`.

## Enter the world

1. The character screen appears about a minute after the window. Take a screenshot
   before clicking.
2. Click **快速登入** (bottom left of the character screen) with
   `"$S/gclick" <pid> <window_id> MapleStory <x> <y>`, check the target, then add `--click`.
3. The first click often only brings the window forward. Take another screenshot
   and click again if the screen did not change.
4. Wait about 30 s for the map to load, then take the window ID again.

## Controls (the test character's key setup)

| Action | Key |
|---|---|
| Move | `left` / `right`; `up` on a portal (the shining spot) enters it |
| Jump | `command` (alone) |
| Attack | `control` (alone) |
| Skills | `a` `s` `d` `f` `q` `w` `e` `r` (`a` damages nearby monsters) |

```bash
"$S/gkey" <pid> <window_id> MapleStory left --hold 400            # preview
"$S/gkey" <pid> <window_id> MapleStory left --hold 400 --send     # send
```

- The **first direction key is ignored**; press it twice to turn.
- Hold a direction with `--hold MS` to walk. To jump while walking, start a second
  `gkey` for `command` while the first is holding.
- `gkey` does not re-activate a game that is already in front: re-activating
  stalls MapleStory for about 200 ms.
- No monsters nearby: wait for them to respawn, or change channel. Walking far
  usually gets the character hurt.
- Never spend, trade, chat, use the cash shop, or delete anything without the
  user's explicit permission.

## Inspect a problem

| Question | Method |
|---|---|
| Which graphics backend really loaded | The `graphics backend=` line in the launch log, and the modules the game loaded. A setting alone proves nothing. |
| Does the frame output stall, and for how long | Metal System Trace + Time Profiler with `xctrace-frames.py` (see "量測卡頓" in [macos-controls.md](../../../.agents/skills/wine-game-compat-testing/references/macos-controls.md)). Do not count ScreenCaptureKit frames: they keep arriving while the game is stopped. |
| What the main thread does during a stall | The `threads` and `where` commands of `xctrace-frames.py` on the Time Profiler table. |
| Whether disk reads cause it | `--io-trace`: `cache_fill` lines carry `t=` (CLOCK_MONOTONIC µs) and `dur_us=`. `<log>.mono` holds the offset to epoch seconds, the clock of `gkey`'s `down_at=`. |
| Cold vs warm | A cold run needs `sudo purge` (user) and a fresh launch. The first hit warms the files, so only the first hit after a purge is cold. |

Timing a first hit:

1. Start the trace with `--time-limit 15s`. Attaching stalls the game for 0.5–4 s,
   so send the key about 8 s after the trace starts.
2. Cast `a` with `--hold 100 --send` and keep the `down_at=` value.
3. A second cast about 3.5 s later gives the warm comparison in the same trace.
4. Keep traces to 13–16 s; a longer one once hung while saving.

Do not run `sample` on the game while measuring: it freezes the game and the HUD.
Change one thing per run (backend, engine patch, cache state) and keep the map,
channel, character position and FPS cap the same.

## Exit and clean up

- Exit through the game's own exit dialog; take a screenshot before confirming.
- If the game will not close, stop only the test session's server:
  `WINEPREFIX=<prefix> <engine>/bin/wineserver -k`, with the same engine the game ran on,
  and only when nothing else uses that prefix.
- Logs, traces and screenshots stay in `$TMPDIR` or `.local/`. Logs and screenshots
  can show the account, so do not commit them. Notes keep only de-identified timings
  and conclusions.
