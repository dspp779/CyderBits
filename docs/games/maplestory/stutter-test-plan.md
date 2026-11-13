# MapleStory first-use stutter: test plan

Tracks [issue #22](https://github.com/dspp779/CyderBits/issues/22). Status:
**plan only, nothing run yet.** The operator steps marked *taught* will be
filled in after the first guided session and then moved into a skill.

## Question

Is loading resources from disk the root cause of the stutter?

"Loading from disk" covers three different costs. The plan measures them
separately, because each has a different fix:

| Cost | What it is | Fix if it dominates |
|---|---|---|
| **Read wait** | Time blocked in file reads (WZ files) | Preload or cache file data |
| **Decode** | Game CPU time after the read: decompress, parse, build sprites | Not fixable in Wine; only earlier triggering helps |
| **GPU setup** | Texture creation, upload, pipeline compile, waiting on submit | Renderer changes (DXVK / DXMT) |

Earlier evidence (2026-09, Apple Silicon, fast SSD) says read wait is *not* the
main cost of the first-hit stall: warming about 119 MiB of WZ ranges changed
nothing, and almost no monster file was read in the hit window. That evidence
has gaps, which is why this plan retests it:

- only selected ranges were warmed, never whole resource folders;
- reads were never lined up against the frame gap on one clock;
- nothing was measured for skill effects or for walking;
- nothing was measured on an old Mac or a slow disk.

## Test machines

| Machine | Backend | Scenes it can answer |
|---|---|---|
| This Mac (Apple M4, macOS 27.2, 16 GB, internal SSD) | DXMT | First hit, first skill effect |
| An old Intel Mac (to be named) | DXVK 1.10.3 + MoltenVK | Walking through a map, plus the two above |

The game folder is about 68 GB and the Mac has 16 GB of memory, so the whole
game cannot be held in the file cache. Warm runs target named folders.

## Scenes

Each scene starts from a **cold game process** (game fully quit and relaunched)
and is done once per run, because the stall happens only the first time.

| ID | Scene | Action | Expected stall |
|---|---|---|---|
| S1 | First hit | Enter a map with monsters; without swinging first, land one basic attack | About 0.65–0.75 s on Apple Silicon |
| S2 | First skill effect | Use one named buff or passive-trigger skill for the first time | Shorter; size unknown |
| S3 | Walking | Walk a fixed route across Henesys (Archer Village) end to end | Unknown; old Macs only |
| S0 | Control | Second hit / second cast / second walk of the same route in the same session | None |

Fixed per series: same character, channel, map, spot, skill, window size and
graphics settings. Record them in the run log.

## What is recorded in every run

1. **Frame gap.** The Metal or DXVK HUD is on and the screen is recorded.
   The stall length is the longest run of identical frames around the action.
2. **Where the game process was.** `sample <pid>` runs across the action and
   shows whether threads sat in file reads, in the game's own code, or in the
   graphics stack.
3. **File reads** (runs marked "I/O trace" only), on the same clock as the
   recording. Two ways; pick one per series:
   - `fs_usage -w -f filesys <pid>`: needs an administrator password, so the
     user starts it.
   - A diagnostic engine build with the I/O summary and timeline patches. The
     shipped engine does **not** contain them (checked: the strings are absent
     from the installed `ntdll.so`), so this needs a separate engine install
     tree. It must never replace the user's normal engine.
4. **Run log.** One line per run: date, engine label, backend, scene, condition,
   stall in ms, felt result, files produced.

## Experiments

Run in this order. Each step changes one thing. Do every condition three times
and alternate conditions (A, B, A, B…) so drift does not look like an effect.

| # | Experiment | Conditions | If disk reads are the cause | If they are not |
|---|---|---|---|---|
| E1 | Baseline with I/O trace | Normal launch | Reads fill most of the stall window | Reads are a small part of it; threads are in game or graphics code |
| E2 | Warm file cache | (a) cold: after a restart or `purge`; (b) warm: read the named WZ folders to `/dev/null` just before launch | Warm is clearly shorter | No difference |
| E3 | WZ cache setting | Advanced → MapleStory WZ cache on / off | Changes the stall | No difference |
| E4 | Slower disk (only if E1/E2 point at disk) | Game on internal SSD / on a slow external disk | Stall grows with the slow disk | Same stall |
| E5 | Decode vs GPU (only if E1/E2 point away from disk) | Read the `sample` output from E1 | n/a | Decide between game CPU and graphics stack |
| E6 | Old Mac walking | E1–E3 repeated for S3, plus DXVK HUD `compiler,pipelines` | Reads line up with each hitch | The compiler indicator lights with each hitch |

Folders for the warm condition in E2, to be confirmed in the taught session by
looking at which files E1 shows being read: `Data/Effect`, `Data/Skill`,
`Data/Mob`, `Data/Character`, `Data/Map` (S3).

## Reading the results

| Result | Conclusion | Next step |
|---|---|---|
| E1 reads cover ≥ 50% of the stall **and** E2 warm removes most of it | Disk read wait is the root cause | Design a targeted preload |
| E1 reads are short, E2 shows no difference, `sample` is in the game's code | Decode is the cost | Renderer and file work will not fix it; only triggering earlier helps |
| E1 reads are short, `sample` is in DXMT / DXVK / Metal | GPU setup is the cost | Renderer proposals in issue #22 |
| Mixed, or runs disagree | Not decided | More runs before any change |

A difference counts only if it is larger than the spread between repeated runs
of the same condition.

## Who does what

| Step | Who |
|---|---|
| Sign in to the game (account, password, one-time code) | User, always |
| Administrator password prompts (`purge`, `fs_usage`) | User |
| Grant Screen Recording and Accessibility | User, once |
| Launching, recording, sampling, moving the character, attacking, quitting | Claude, after the taught session |
| Reading traces and writing the result | Claude |

Limits Claude keeps during runs: no spending, no trading, no chat, no deleting
anything in the game; only the taught actions on the agreed map; stop and ask if
the screen is not what the steps describe.

## Taught session (first time)

The user shows these once; Claude writes them down as they happen:

1. How the game is launched and where sign-in hands over.
2. How to reach the test map and the exact standing spot.
3. Which keys move, attack and cast; which skill is used for S2.
4. How to tell "first hit landed" on screen.
5. The walking route for S3.
6. How to leave the game cleanly.

After that session, the steps become a skill under `.agents/skills/`, and the
reusable parts go to `docs/games/maplestory/testing.md`.

## First session notes (2026-11-13)

Taught steps as found:

1. **Launch:** Beanfun OTP (signed in) → account `dspp779` → 啟動遊戲 →
   character screen → 快速登入 (character 幻瞑月牙 Lv.130, 愛麗西亞). The
   Beanfun session expires; after that the user must scan the QR code again.
2. **Map:** from the town, walk right to the shining portal at the right
   edge, press up → 菇菇歌唱森林 / 芽孢山丘 (green mushrooms). Drop right to
   the small ledge, then jump right onto the long mid platform.
3. **Keys:** arrows move, Command jumps, Ctrl attacks, skills on
   A S D F Q W E R. K opens the skill window, Esc closes panels, a second Esc
   opens the menu.
4. **First hit landed:** attack pose and, for this low-level map, the notice
   "狩獵不在等級範圍內的怪物時…".
6. **Quit:** Esc Esc → 遊戲結束 → 是 only returns to character select. A
   real exit is the window close button → 遊戲結束 (process gone after ~8 s).

Tools: the game window has no bundle ID, so computer use cannot grant it.
Use `wine-windows.swift` (IDs), `screencapture -l <window>` (view),
`guarded-click.swift` / `guarded-key.swift` (input). Frame gaps were taken
with a ScreenCaptureKit recorder that logs the time of every changed frame
(idle frames skipped).

Run log:

| Run | Scene | Result | Notes |
|---|---|---|---|
| 1 | S1 | **Not valid** | First hit landed during an unrecorded key-tool test |
| 1 | S0 | Longest gap 31 ms, ~60 fps | Later hit, no `sample` running |
| 1 | S2 | Longest gap 52 ms | First skill (A); `sample` was running and itself slows frames (228 vs 302 frames / 5 s) |
| 2 | S1 | **Longest gap 39 ms**, 353 frames / 6 s | Cold game process (relaunched), first basic attack killed two mushrooms. OS file cache **warm** (game had run 30 min earlier, no `purge`). DXVK + MoltenVK. The character took one monster hit at login before the attack |
| 2 | S0 | Longest gap 32 ms, 360 frames / 6 s | Second hit, same process |

| 3 | S1 | **Longest gap 40 ms**, 358 frames / 6 s | Cold process **and cold file cache** (`sudo purge` after a full quit, then relaunch). First attack killed a mushroom (+12 EXP). HUD showed a short run of ~35 ms frames right after the hit. DXVK + MoltenVK |
| 3 | S0 | Longest gap 31 ms, 362 frames / 6 s | Second hit, same process |

Reading of runs 2–3: on DXVK, the first hit showed **no stall** either with a
warm file cache (39 ms) or after `purge` (40 ms), against 31–32 ms for the
second hit. The 0.65–0.75 s first-hit stall did not reproduce, so on this
backend disk reads are not causing one. The recorder does catch stalls of
this size: it saw 200–240 ms gaps when the window was re-activated.

Still open: DXMT (the earlier 0.65–0.75 s evidence may come from that
backend), repeats (one run per condition so far), and the monster hit taken
at login before the first attack in every run.

Side finding: relaunching ~40 s after a full quit failed once with
`CYD-WIN-001` "Unable to reserve native executor ownership: busy" (exit 75,
stage `wine-spawn`); the next click a minute later launched normally.

Corrections to this plan:

- The game here runs on **DXVK** (`dxvk-submit`, `dxvk-queue`, `dxvk-cs`
  threads in `sample`), not DXMT. Confirm the backend per run.
- Do not run `sample` during frame-gap runs; do it in separate runs.
- The character was hit by a monster before the first attack; take that as a
  possible warm-up of damage resources and avoid contact in S1 runs.

## Not covered

- D3DMetal: closed source, and not the default path.
- Fixing anything. This plan only decides where the time goes.
