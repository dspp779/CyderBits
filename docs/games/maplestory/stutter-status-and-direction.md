# MapleStory stutter: status after 0.15.0 and direction for 0.16.0

Date: 2026-11-22. Issues: [#22](https://github.com/dspp779/CyderBits/issues/22)
(the three symptoms), [#25](https://github.com/dspp779/CyderBits/issues/25)
(the first-hit read study). Measurements and methods:
[stutter-test-plan.md](stutter-test-plan.md).

## Summary

MapleStory on Cyder has three kinds of "first time" stutter. Only one of them
has been measured:

| Symptom | Where | Measured? | Fixed in 0.15.0? |
|---|---|---|---|
| **First real hit** after login freezes the picture | All Macs | Yes, on Apple Silicon (M4), one cold run per condition | Partly: WZ read-ahead removes ~250 ms of read waiting; the rest remains |
| **First use of a skill or effect** stutters | All Macs | No valid measurement | No |
| **Walking through a map** stutters | Old Intel Macs (DXVK + MoltenVK) | Never | No |

The first-hit freeze has two parts: waiting for WZ file reads (about
two-thirds of the DXVK freeze before 0.15.0) and the game's own first-use work
on the CPU under Rosetta. 0.15.0 attacks the first part. How much of it players
on the default backend (DXMT, macOS 15+ Apple Silicon) actually feel is **not
established**: the only DXMT pair did not show a shorter freeze.

## 1. First hit (Apple Silicon)

### What happens

On the first damaging attack after login, the main game thread stops producing
frames for about 0.4–1.0 s. The graphics threads go idle; the main thread is
busy in game code or waiting on file reads. The same hit later in the session
does not stall. All three backends (DXVK, DXMT, D3DMetal) show it.

The waiting part is a fixed read set: about 5,500 forward-strided 8 KiB reads
(8–208 KiB apart) in `Data/Sound/Sound_030.wz` and
`Data/Etc/_Canvas/_Canvas_009.wz`, 43 MB in total, identical between sessions
([read set](first-hit-readset-2026-11.tsv)). macOS only reads ahead for
contiguous reads, so each 8 KiB fill of Cyder's WZ cache waited for the SSD
alone (~70 µs), about 370–390 ms per first hit. Windows avoids this with
cache-manager read-ahead and a long-lived standby list.

### What 0.15.0 ships

`maplestory-cx26-wz-readahead.patch` (engine Cyder014): once fills on a handle
move forward, it issues an asynchronous `fcntl(F_RDADVISE)` for the next 2 MiB.
Cyder turns it on with the WZ cache under one setting, **MapleStory WZ read
optimization, on by default**.

One cold run per cell (runs 7–14 in the test plan):

| Backend | Read waiting, off → on | Longest freeze, off → on |
|---|---|---|
| DXVK | 388 → 108 ms | ~1.0 s → 0.29 s (+ a second gap of 0.21 s) |
| DXMT | 379 → 135 ms | 0.38 s → 0.44 s (the "on" run killed two monsters: more CPU work) |
| D3DMetal | 379 → 112 ms | 0.40 s → 0.28 s |

### What remains (read-ahead on)

Main game thread, 1.1 s after the first hit. A normal second is ~250–310 ms
on the CPU, almost all game code.

| Part | DXVK | DXMT | D3DMetal | Can Cyder reduce it? |
|---|---|---|---|---|
| Game code under Rosetta | ~420 ms | ~400 ms | ~360 ms | No. About 170 ms more than a normal second: the game's first-use work |
| Wine syscall entry and exit | ~100 ms | ~220 ms | ~110 ms | Partly, with fewer calls. DXMT's extra share is its graphics unix calls |
| WZ cache work (fills from page cache, hits) | ~85 ms | ~120 ms | ~95 ms | Yes |
| I/O trace logging | ~25 ms | ~25 ms | ~25 ms | Test-only; absent in normal play |

The longest single gap is a misleading summary: the DXVK run with read-ahead
has a 0.29 s gap followed by a 0.21 s one, about 0.5 s of disturbed frames.
Report both the longest gap and the total time below ~30 fps.

### How sure we are

- **Every number above is one run.** The planned repeats (next.md A5) were
  skipped for 0.15.0.
- **DXMT is the default on macOS 15+ Apple Silicon**, and its pair is the
  weakest evidence: read waiting dropped, the freeze did not. Whether 0.15.0
  shortens the freeze for most players is unknown.
- Measured on one Mac (M4, 16 GB, internal SSD), one character, one map, one
  skill. Other classes and maps read other files.
- The engine-side estimates below (100–130 ms more) come from profiles, not
  from runs.

### Superseded statements

These still appear in older documents and should not drive the plan:

| Statement | Where | Why it is superseded |
|---|---|---|
| The stall is mostly `AGXBuffer initImplWithHeap` / Metal buffer allocation ("first-use materialization") | Issue #22 body; engine `maplestory-wine-breakthrough-opportunities.zh-TW.md` §1.2 (2026-11-11) | Run 5 (Time Profiler on the game thread) shows the graphics thread idle and the main thread in game code and `NtReadFile`. Thread names in earlier samples did not show where the main thread was |
| WZ I/O work should stop being a first-hit direction | Same engine document, §7 | Runs 7–14: read waiting was ~two-thirds of the DXVK freeze; the earlier prewarms warmed the wrong files or warmed them minutes too early |
| "Warming 119 MiB changed nothing, so reads are not the cause" | Test plan, 2026-09 evidence | Those ranges were not the hit-path files, and page-cache residency on a 16 GB Mac lasts only minutes |
| Frame-gap numbers in runs 1–4 | Test plan | ScreenCaptureKit kept reporting frames while the game was stopped. Only Metal System Trace present gaps are valid |

## 2. First use of a skill or effect

Each skill, buff, passive trigger, level-up and critical effect seems to stall
once, separately. No valid measurement exists: the S2 runs used the invalid
frame-gap method, and the one warm cast under a valid trace had a 994 ms gap
with no idle baseline to compare.

The same read-set method applies: record `CYDER_IO cache_fill` events around
the first cast and see which files it scans. Whether read-ahead already helps
here is unknown.

## 3. Walking on old Intel Macs

Never measured. Known so far (iMac12,2, GTX 780M, macOS 15.8, 2026-11-16):
MapleStory runs on DXVK 1.10.3 + MoltenVK 1.4.2; walking and skills work; the
WZ cache and read-ahead variables reach the game; a DXVK state cache file from
11-11 exists and a short session added no entries. That Mac has no Xcode, so
Metal System Trace is not available there.

Candidate causes, from reading the source only (issue #22 comment,
2026-11-12), none timed:

1. DXVK 1.10.3 compiles missing pipelines synchronously inside the draw call,
   and MoltenVK compiles Metal shaders synchronously below it.
2. Texture creation while walking: Cyder's 0.14 black-texture fix expands every
   4-bit texture to 8-bit with a scalar CPU loop on Intel/AMD GPUs.
3. WZ cache fills on a slower disk.

## Directions for 0.16.0

Ranked by evidence and cost. Each step has the measurement that decides
whether to go on.

| # | Direction | Work | Expected effect | Go / no-go |
|---|---|---|---|---|
| D0 | **Repeat the first-hit baseline** with the 0.15.0 release engine: DXMT first, then DXVK and D3DMetal; read optimization on and off; ≥3 cold runs each, alternating | Hours per backend, no code. Tools exist: `wine-game-compat-testing/scripts/xctrace-frames.py`, `readbench.c`, `replay-readahead.c` | Establishes whether 0.15.0 helps the default backend, and the size of what is left | Gates everything below. If on/off differ by less than the run-to-run spread on DXMT, the remaining DXMT freeze is CPU work: skip D1/D2 for DXMT and go to D3 |
| D1 | **Engine WZ cache follow-ups** (issue #25): a 256 KiB fill window once a handle is in read-ahead mode; serve hits without the two `lseek`s (0.81 → 0.53 µs per hit, measured); fill outside the global mutex | Engine patch plus patch tests; a game A/B | ~100–130 ms of the DXVK freeze (estimate); less CPU in normal play | Do if D0 shows ≥100 ms of `NtReadFile`/cache work left on the main thread |
| D2 | **Learned hit-path prefetch (app only)**: record the windows the first hit fills, keyed by game version and file size/mtime; after the game window appears, a low-priority helper reads them with many reads in flight and re-touches them every 1–2 minutes | App helper plus tests; ~43 MB page cache | Run 8 (files warmed just before): fills 13 ms versus 108–135 ms with read-ahead, ~100 ms more | Do if D0 shows read-ahead leaves ≥100 ms of fills. Must relearn after a game patch and union read sets across characters and maps |
| D3 | **DXMT first-use CPU**: finish the DXMT resource lab (built, CPU tests pass, GPU acceptance never run) and use its upload/submit timers on a real first hit; count DXMT unix calls during the freeze | Engine/DXMT work already half done | Unknown; DXMT's syscall share is ~110 ms higher than the other backends | Do if D0 confirms DXMT's freeze is not reads |
| D4 | **Old Intel Mac: measure walking first.** DXVK HUD `compiler,pipelines,frametimes` while walking Henesys; WZ optimization on and off | Hours, no code | Tells pipeline compile from texture upload from disk | Compiler indicator lights with each hitch: try MoltenVK concurrent compilation, then a default-off DXVK async-pipeline patch. It does not: vectorize the 4-bit texture expansion, or look at reads |
| D5 | **Skill-effect read sets** (symptom 2): same `cache_fill` capture for two or three skills | Hours, no code | Shows whether D1/D2 also cover skills | If the files differ per skill, D2's learned list must cover them |
| D6 | **Player hint:** "after entering a map, hit a monster once" in the player guide and the game's tips | Minutes | Moves the remaining freeze to a moment the player chooses | Always; the only measured remedy for the CPU part (not in the guide today) |

### Not planned for 0.16.0

- Whole-file `cat`/prewarm at launch: pages are evicted within minutes.
- More Skill/Effect range prewarm, `FAST_HIT`, H2 in-process prewarm: already
  shown to warm the wrong data.
- Switching backends as a fix: all three stall.
- The ~170 ms of extra game code under Rosetta. Only a different architecture
  (ARM64 Wine + FEX) could change it; that is long-term research, not a 0.16.0
  item.

## Proposed 0.16.0 goal

Measured, not promised as a percentage:

- For each backend, the first real hit after a cold start (same character, map
  and skill) has a **median of at least three runs** for the longest present
  gap and for the total time below ~30 fps, with the read optimization on and
  off.
- Any new change (D1, D2, D3) ships behind a setting or flag, with its own
  on/off median, and login, sustained play and exit checked.
- The old Intel Mac has a reproducible walking route with DXVK HUD frame
  times, and a stated cause.

## Open questions

- Does read-ahead shorten the freeze on DXMT, the default backend? (D0)
- Is the DXVK state cache read back on the next launch on the Intel Mac, and
  does it matter for walking? (D4)
- Do other characters, classes and maps read the same 43 MB? (D2, D5)
- What does prefetch do to memory pressure on 8 GB Macs? (D2)
