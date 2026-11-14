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
`guarded-click.swift` / `guarded-key.swift` (input).

**Measurement correction (2026-11-13, later the same day): every frame-gap
number in runs 1–4 below is invalid.** They came from a ScreenCaptureKit
recorder that logged "complete" frames of the game window. A check with
`kill -STOP` on the game for 0.5 s showed the recorder still logging ~60
frames/s with no gap, so it does not follow the game's presents. Hashing
the pixels does not fix it either: the game area and the Metal HUD both stay
unchanged for up to ~1 s on a quiet screen, which looks like a stall.

The valid method is the one the engine-side experiments used
(`../cyder-wine-engine/docs/maplestory-cx26-first-hit-prewarm-design.zh-TW.md`):
an Instruments **Metal System Trace**, reading the gaps between the game's
`ca-client-present-request` events. From the shell:

```bash
xcrun xctrace record --template "Metal System Trace" --attach <pid> --time-limit 12s --output run.trace
xcrun xctrace export --input run.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="ca-client-present-request"]' > presents.xml
```

The same 0.5 s `kill -STOP` shows up there as a present gap starting within
30 ms of the stop. Caveats found so far: attaching causes a ~3 s present gap
at the start of every trace (act at least 4 s after it starts); one warm
air-swing cast of A was followed by a 994 ms gap that still needs an idle
baseline to interpret; and one 10 s trace hung while saving and was lost.

Run log (frame-gap columns invalid, see above; what happened in game is still
true):

| Run | Scene | Result | Notes |
|---|---|---|---|
| 1 | S1 | **Not valid** | First hit landed during an unrecorded key-tool test |
| 1 | S0 | Longest gap 31 ms, ~60 fps | Later hit, no `sample` running |
| 1 | S2 | Longest gap 52 ms | First skill (A); `sample` was running and itself slows frames (228 vs 302 frames / 5 s) |
| 2 | S1 | **Longest gap 39 ms**, 353 frames / 6 s | Cold game process (relaunched), first basic attack killed two mushrooms. OS file cache **warm** (game had run 30 min earlier, no `purge`). DXVK + MoltenVK. The character took one monster hit at login before the attack |
| 2 | S0 | Longest gap 32 ms, 360 frames / 6 s | Second hit, same process |

| 3 | S1 | **Longest gap 40 ms**, 358 frames / 6 s | Cold process **and cold file cache** (`sudo purge` after a full quit, then relaunch). First attack killed a mushroom (+12 EXP). HUD showed a short run of ~35 ms frames right after the hit. DXVK + MoltenVK |
| 3 | S0 | Longest gap 31 ms, 362 frames / 6 s | Second hit, same process |
| 4 | S2 (skill A) | Longest gap 40 ms (invalid) | Safe spot on the samurai map chosen by the user; warm cache. Two air casts first (faced right), then the first damaging cast (28605 / 28503) |

No conclusion about the first-hit stall can be drawn from runs 1–4.

### Run 5: first damaging cast under a Metal System Trace (valid)

Fresh process (PID 45627), DXVK + MoltenVK, warm file cache (no `purge`),
楓葉丘陵 / 紅葉原3, CH.7. Trace: `Metal System Trace` + `Time Profiler`,
attached to the game. First cast of A hit three samurai (MULTIKILL 3).

Presents of the game (`ca-client-present-request`), per 200 ms:

| Time (epoch, s) | Presents / 200 ms | What happened |
|---|---|---|
| 202.6–203.0 | 0 | Trace attach disturbance (before any input) |
| 203.0–203.6 | 11–12 (≈60 fps) | Normal |
| 203.617 | — | Key down: first cast of A |
| **203.664–204.749** | **2 presents in 1.09 s** | **First-hit stall** |
| 204.8 onward | 11–12 | Normal; the second cast (air, 207.178) shows no dip |

Main game thread (`0x169ddee`) during equal 1.085 s windows, from the Time
Profiler (1 ms samples; only on-CPU time is sampled):

| Window | On CPU | Game code (Rosetta JIT) | Wine syscall path (`ntdll.so`) | of which `NtReadFile` |
|---|---|---|---|---|
| First-hit stall | 555 ms | 354 ms | **201 ms** | **≥ 76 ms** |
| Normal second | 292 ms | 289 ms | 3 ms | 0 |
| Normal second #2 | 359 ms | 353 ms | 6 ms | 0 |
| Trace attach gap (run 5) | 130 ms | — | 0 | 0 |
| Trace attach gap (run 6) | 27 ms | — | 2 ms | 0 |
| Warm damaging cast (run 6, inside attach noise) | 454 ms | — | 10 ms | 0 |

`dxvk-submit` ran 26 ms during the stall vs 375 ms in a normal second: the
graphics thread was idle because the main thread stopped producing frames.

Reading (one valid run so far):

- The stall is **not graphics**: the render/submit path goes quiet, and the
  main game thread is busy instead. This matches the user's report that DXMT,
  D3DMetal and DXVK all stall.
- The main thread spends a large, new share of the stall in **file-read
  syscalls through Wine (`NtReadFile`)**, which a normal second and a warm
  cast never show. With a warm file cache these reads cost CPU in the
  syscall path, not disk wait.
- About half the stall (≈ 530 ms) is off-CPU and not explained by this
  profile; it may be blocking inside those reads, wineserver round-trips, or
  locks. A syscall-duration trace (`System Call Trace` instrument, or
  `fs_usage`) is the next measurement.
- The earlier "read wait is not the main cost" (warming 119 MiB changed
  nothing) is about disk latency; this run points at the per-read cost on
  the main thread instead, the topic of
  `../cyder-wine-engine/docs/maplestory-cx26-small-read-fast-path-plan.zh-TW.md`.

Method notes: attaching `xctrace` disturbs presents for 0.5–4 s at the start
of a trace and the length varies, so check that presents are back at ~60 fps
before the action. The run 6 warm control was lost to that. A long trace
(10 s idle, no Time Profiler) once hung while saving.

### How much the reads can cost (2026-11-14)

**Read volume.** One session with the engine's own I/O log
(`WINEDEBUG=-all,+cyderio CYDER_MAPLESTORY_IO_TRACE=1
CYDER_MAPLESTORY_IO_PROFILE=1`, summaries written as handles close) covered
login, character select and map load. It made 981,889 `NtReadFile` calls on
`.wz` files:

- 845,051 tiny reads; the `_Canvas_000.wz` files average about 3.5 bytes per
  call (e.g. `Character/Hair/_Canvas/_Canvas_000.wz`: 124,111 calls, 434 KB).
- 965,234 (98 %) were served from Cyder's file cache.
- Real host reads were 16,842 calls taking 0.78 s in total; cache fills
  were 581 taking 64 ms.

**Per-call cost.** `scripts/readbench.c` in the testing skill (built with the
engine's llvm-mingw, run with the shipped engine on
`Data/Character/Hair/_Canvas/_Canvas_000.wz`, 100,000 calls):

| Read style | Cyder cache on | Cache off |
|---|---|---|
| File pointer (how MapleStory reads: `offs=0 unknown=N` in the summaries) | 0.81 µs | 0.62 µs |
| Explicit offset | 0.53 µs | 0.86 µs |
| Empty seek (one Wine call, baseline) | 0.64 µs | 0.63 µs |

Reading:

- A cached tiny read costs under 1 µs. Even 100,000 of them cost about 80 ms,
  so faster reads can remove at most the 76–201 ms of syscall time seen in
  the stall, never the whole 1.09 s. This matches the earlier FAST_HIT and
  prewarm results: no perceptible change.
- For file-pointer reads, Cyder's cache is **slower** than no cache (0.81 vs
  0.62 µs): the cache path adds `lseek( SEEK_CUR )` and `lseek( SEEK_SET )`
  around every hit (`dlls/ntdll/unix/file.c`, `NtReadFile`). Worth fixing for
  general CPU use, but it is not the stall.
- The stall is therefore mostly the ~354 ms of game code on the CPU and the
  ~530 ms when the main thread is off the CPU. What it waits on is the open
  question.

Still open: what the main thread waits on during the stall (a `sample` run
shows blocked stacks; it slows the game but the blocking frames should still
show), repeat run 5 (and a clean warm damaging control), cold vs warm file
cache, DXMT.

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
