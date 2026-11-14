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

### What the main thread waits on: cache-window fills that miss the page cache (2026-11-15)

**`sample` during a first hit** (fresh process, DXVK): of the main game
thread's waiting samples, 124 of 192 sit in a kernel call made from
`cyder_maplestory_file_cache_read + 1011`. That call is the `pread` that
refills the cache window (`file.c`, `pread( fd, entry->data, window_size,
window_offset )`, done while holding the cache's global mutex). Most other
waits are file-position calls (`NtSetInformationFile`,
`NtQueryInformationFile`) and other spots in `NtReadFile`.

**I/O log around the casts** (`CYDER_IO cache_fill` events with timestamps,
aligned to `guarded-key`'s `down_at`; 1.2 s after each key):

| Window | Cache fills | Time in fills |
|---|---|---|
| Quiet baseline | 1 | 0 ms |
| First damaging cast | 5,501 on 7 handles | 366 ms (≈ 67 µs each) |
| Warm damaging cast (same process) | 17 | 0.8 ms |

99 % of the first-hit fills are distinct 8 KiB windows, not re-reads. The
files (from the fds via `lsof`):

| File | Size | Fills | Time |
|---|---|---|---|
| `Data/Sound/Sound_030.wz` | 370 MB | 4,048, scattered over the whole file | 276 ms |
| `Data/Etc/_Canvas/_Canvas_009.wz` | 94 MB | 770 | 78 ms |
| `Data/Etc/Etc_000.wz` | 14 MB | 579 | 3 ms |
| `Data/Sound/Sound_033.wz`, `Sound_040.wz` | 38 / 299 MB | 56 / 32 | 9 ms |

67 µs per 8 KiB `pread` is an SSD random read: natively, random 8 KiB reads
of `Sound_030.wz` cost 86 µs on the first pass and 1 µs on the second. The
files are not APFS-compressed.

**The read set is fixed.** Two sessions read exactly the same windows on the
first hit (Jaccard 1.00 per file): 5,463 windows, 43 MB.

**Page-cache residency is short.** A `cat` of the five files (815 MB, 0.28 s)
keeps them resident only for minutes on this 16 GB Mac under load: a file read
6 minutes earlier answered random reads in 72 µs again. Warming 4 minutes
before the hit (run 7) changed nothing: 5,728 fills, 388 ms, stall unchanged.
The earlier H1 prewarm also targeted Skill/Effect ranges, not these files.

### Run 8: warm the files just before the first hit (valid)

Fresh process, CH.7, same pillar. The five files were read with `cat` about
6 s before the cast (random reads on `Sound_030.wz` then cost 1.8 µs). Metal
System Trace + Time Profiler + I/O log.

| | Run 7 (files evicted) | Run 8 (files warmed just before) |
|---|---|---|
| Fills in the first hit | 5,728, 388 ms (68 µs each) | 5,728, **12.7 ms** (2.2 µs each) |
| Longest present gap | ~1.0 s with 0–1 frames per 200 ms | **295 ms**, then one 140 ms gap |
| Presents per 200 ms after the key | 1, 1, 12, 0, 0, 9 | 5, 3, 12, 6, 11, 12 |

The cast hit in both runs (EXP rose, MP spent). One run each.

**Reading:** about two thirds of the first-hit freeze is the main thread
waiting for ~5,500 scattered 8 KiB SSD reads, one at a time, through Cyder's
single-window WZ cache. With those 43 MB resident, the freeze drops from about
1 s to about 0.3 s. The remaining ~0.3 s is the game's own first-use work on
the CPU (and Rosetta), which no file change will remove.

### Why Windows does not stall here (2026-11-15)

**The pattern is a forward scan, not random access.** In the first hit:

| File | Reads | Direction | Step between reads | Cost per fill |
|---|---|---|---|---|
| `Sound_030.wz` | 4,048 in 0.39 s | 100 % forward, from offset 8 KiB | 8–208 KiB (median 40 KiB) | 68 µs |
| `_Canvas_009.wz` | 770 | 99 % forward | median 104 KiB | 101 µs |
| `Etc_000.wz` | 579 | forward | exactly 8 KiB (contiguous) | **5 µs** |

macOS read-ahead only engages for contiguous reads: `Etc_000.wz` is
contiguous and its fills cost 5 µs; the strided scans miss it, so each 8 KiB
read waits for the SSD alone (queue depth 1).

**Windows (from its documented design, not measured here):**

- The NT cache manager's *intelligent read-ahead* keeps a short history of
  reads per handle and recognises forward (and strided) progress, then reads
  ahead in larger units asynchronously on system worker threads. A strided
  forward scan like this one becomes mostly cache hits on the game thread.
- File pages are kept on the standby list until memory is really needed, and
  SysMain (Superfetch) prefetches what an application usually reads. Game data
  read in earlier sessions tends to still be in memory.
- Each cached `ReadFile` is a short kernel copy. Here every call also goes
  through Rosetta and Wine, and Cyder's cache refills one 8–32 KiB window per
  handle at a time, under a global lock.

So on Windows the same reads are usually in memory, and if not, read-ahead
fetches them in bulk in the background. On macOS under Wine they become
thousands of blocking 8 KiB SSD reads, and pages from earlier sessions are
evicted within minutes on a 16 GB Mac.

**Native replay** (`scripts/replay-readahead.c`): the real `Sound_030.wz`
step sequence replayed on large Sound files nobody had read recently:

| Mode | Per 8 KiB read | Total (scaled to 4,048 reads) |
|---|---|---|
| Plain `pread` (cold) | 72 µs | ≈ 290 ms (matches the 276 ms in game) |
| `fcntl(F_RDADVISE)` read-ahead, 1–8 MiB chunks, 1–32 queued | 30–33 µs | ≈ 120–130 ms |
| Plain `pread`, data already cached | 5.5 µs | ≈ 22 ms |

With read-ahead the scan becomes bandwidth-bound (the stride spans the whole
file, so all of it is read at about 3.5 GB/s) instead of latency-bound. Deeper
look-ahead does not help further.

### Run 10: engine read-ahead prototype (valid)

Patch `maplestory-cx26-wz-readahead.patch` (engine branch
`claude/wz-readahead`), built into a copy of the installed engine with only
`ntdll.so` replaced, run with `CYDER_MAPLESTORY_READAHEAD=1`. Before the run
the hit-path files were confirmed out of memory (random 8 KiB reads ≈ 95 µs).
Fresh process, DXVK confirmed in the launch log, CH.7, same pillar; the first
cast killed a samurai.

| | Run 7: no read-ahead, files evicted | Run 8: files warmed by hand just before | **Run 10: read-ahead on, files evicted** |
|---|---|---|---|
| Fills in the first hit | 5,728, 388 ms | 5,728, 12.7 ms | 5,501, **108 ms** (20 µs each) |
| Longest present gap | ~1.0 s | 295 ms (+140 ms) | **291 ms (+208 ms)** |
| Presents per 200 ms after the key | 1, 1, 12, 0, 0, 9 | 5, 3, 12, 6, 11, 12 | 2, 4, 11, 3, 10, 12 |

Read-ahead brings the cold first hit to about the same frame pattern as
fully warmed files, with no learned list. One run each.

### Runs 11–12: DXMT, read-ahead off vs on (valid)

Same test engine copy, `CYDER_GRAPHICS_BACKEND=dxmt` (launch log:
`graphics backend=dxmt … dxmt/0.80`), hit-path files confirmed out of memory
before each launch, CH.7, same pillar. Both first casts landed (run 11: one
kill; run 12: two kills).

| | Run 11: DXMT, read-ahead off | Run 12: DXMT, read-ahead on |
|---|---|---|
| Fills in the first hit | 5,728, **379 ms** (66 µs each) | 5,904, **135 ms** (23 µs each) |
| Longest present gaps | 382 ms + 310 ms | 437 ms + 227 ms |
| Presents per 200 ms after the key | 5, 1, 11, 5, 0, 7 | 5, 0, 7, 4, 7, 12 |
| Main thread on CPU, 1.1 s after the key | 542 ms | 733 ms |

On DXMT read-ahead removes the same ~250 ms of read waiting as on DXVK, but in
this pair the freeze did not get shorter: the main thread spent the time on
the CPU instead (run 12 also killed two monsters, so it had more first-use
work). The DXMT first hit has a larger CPU-bound part than DXVK (DXVK with
warm reads: ~0.3 s), so reads are a smaller share of its stall. One run each;
repeats needed before drawing a firmer conclusion.

Run 12's first attempt missed (one `left` press did not turn the character;
press it twice) and was retried in the same process before any hit.

### Runs 13–14: D3DMetal, read-ahead off vs on (valid)

Same test engine copy, `CYDER_GRAPHICS_BACKEND=d3dmetal` with Cyder's GPTK
variables (launch log: `graphics backend=d3dmetal … apple_gptk`; HUD shows
Game Porting Toolkit 4.0b3), files cold before each launch, CH.12, same
pillar. Both first casts landed (run 13: two kills; run 14: one kill).

| | Run 13: D3DMetal, read-ahead off | Run 14: D3DMetal, read-ahead on |
|---|---|---|
| Fills in the first hit | 5,730, **379 ms** (66 µs each) | 5,728, **112 ms** (20 µs each) |
| Longest present gaps | 372 ms + 403 ms | **279 ms + 190 ms** |
| Presents per 200 ms after the key | 3, 0, 12, 4, 0, 8 | 3, 5, 12, 2, 12, 11 |
| Main thread on CPU, 1.1 s after the key | 585 ms | 572 ms |

With equal CPU work, read-ahead shortened the D3DMetal freeze by about the
read time it removed (two freezes of ~0.4 s → ~0.28 s and ~0.19 s). One run each.

**Summary across backends (one cold run per cell):**

| Backend | Read waiting off → on | Longest freeze off → on |
|---|---|---|
| DXVK | 388 → 108 ms | ~1.0 s → 0.29 s |
| DXMT | 379 → 135 ms | 0.38 s → 0.44 s (run with more CPU work) |
| D3DMetal | 379 → 112 ms | 0.40 s → 0.28 s |

Read-ahead removes ~250–270 ms of read waiting on every backend; how much of
that shows as a shorter freeze depends on the backend's own first-use CPU work.

Run 9 (discarded): the engine copy fell back to wined3d because its
`lib/dxvk` and `lib/dxmt` links are relative to `~/.cyder/runtime`. A copied
engine needs those links made absolute before testing; check the
`graphics backend=` line in the launch log.

## Proposed fixes (ranked)

1. **Engine: Windows-style read-ahead in `NtReadFile` (better, general fix).**
   Keep the last few read offsets per file handle. When reads progress forward
   (contiguous or strided, gaps up to ~1 MiB), call `fcntl(fd, F_RDADVISE)` for
   the next 1–2 MiB beyond a moving frontier, the way the NT cache manager
   reads ahead. It is asynchronous and costs no syscall per read on the hit
   path, needs no learned data, and works for any game file and any
   class/map. Expected for this stall: fill time 366 ms → ~130 ms (native
   replay), i.e. the freeze from ~1 s to ~0.75 s. Can be limited to cached
   (non-`FILE_FLAG_NO_BUFFERING`) handles and disabled for
   `FILE_FLAG_RANDOM_ACCESS`, matching Windows semantics. Belongs in the
   engine repo, behind a flag first.
2. **Learned hit-path prefetch (Cyder, no engine change).** Record the
   windows the first hit reads (from `CYDER_IO cache_fill` with
   `CYDER_MAPLESTORY_IO_TRACE`), keyed by game version and file size/mtime.
   On later launches, once the game window is up, a low-priority helper
   `pread`s those 43 MB with many reads in flight, and re-touches them every
   minute or two so they are not evicted. Measured effect (run 8): ~1 s →
   ~0.3 s. Cost: ~43 MB of page cache and a few ms of I/O per minute. Risks:
   list goes stale after a game patch (detect by size/mtime and relearn);
   other classes, maps or skills read other files (learn per session, union
   the lists). Complements fix 1: fix 1 covers what has not been learned.
3. **Engine: several windows per handle and no fills under the global
   mutex.** Today one 8–32 KiB window per handle is refilled under a global
   lock. More windows help repeated access; moving the `pread` out of the
   lock helps other threads. Small gain for this stall (its reads are new
   data), but cheap and safe.
4. **Engine: drop the two `lseek`s per cache hit** (track the file position
   for cached handles). The cache is slower than no cache for file-pointer
   reads (0.81 vs 0.62 µs). General CPU win, not the stall.
5. **Keep M0** (hint: hit a monster once after entering a map) for the
   remaining ~0.3 s, which is CPU work inside the game.

Not worth doing: bulk `cat`/prewarm of whole files at launch (evicted within
minutes), more prewarm of Skill/Effect ranges, renderer changes for this
stall.

Still open: repeat run 8 (one run so far), learn the read set for other
characters/classes and maps, measure memory pressure with prefetch running,
DXMT and D3DMetal with the same warm-up.

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
