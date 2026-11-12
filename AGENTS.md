# Agent instructions (CyderBits)

This repo is the **application layer**: Cyder.app, bottles, CompatDB, game UX.
The Wine engine that runs `.exe` files is the sibling repo
[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine).

| Checkout | Path |
|---|---|
| CyderBits (this repo) | `~/ogom/Cyderbits` |
| Engine | `~/ogom/cyder-wine-engine` (`../cyder-wine-engine`) |

`build/`, `install/`, `.brew-x86` and `tools/archives` here are links into the
engine checkout.

## Rules

1. **Engine work goes to the engine repo.** Anything about wineserver, ntdll,
   Wine patches, host `make`, minOS or engine packing: open
   `../cyder-wine-engine`, read its `AGENTS.md`, and run its scripts from there
   so `.env` and paths resolve.
2. **Commit on a `claude/<topic>` branch. Merge, push, tag, publish and delete
   only when the user asks**, and only what they named.
3. **Never commit** `.local/`, `.research/`, `.tmp-*/`, `auth/`, `.env`. Never
   print values from `.env` or `auth/`.
4. **Unmerged work lives on a branch**, never only in an ignored folder. Before
   deleting or pruning anything, look at it: `git status`, `git stash list`,
   `git worktree list`, and the folder's contents.
5. **Say what was not tested.** A passing suite, a hash match or a notarized
   zip is not a game test.
6. **Every behaviour change gets a test** in the narrowest `tests/test-*`.
7. **Docs:** user-facing docs are zh-TW; agent and process guides are English.
   When a session teaches something reusable, update the matching skill or doc
   in the same change.

## How to

| Task | Steps |
|---|---|
| Run tests | `bash tests/run.sh <word>` for matching tests, then `bash tests/run.sh` (about 12 minutes; run it in the background). |
| Try a change in the app | Skill `cyder-dev-test`: build with `--channel test` into a folder outside `dist/`, pick the signature, check the app, read the logs. |
| Test a game | Skills `cyder-dev-test` then `wine-game-compat-testing`; per-game steps in `docs/games/<game>/testing.md`. |
| Ship a release | Skill `cyder-release`, start to finish. Never skip `cyder-release-verify`. |
| Write release notes | `docs/release-notes-guide.md`. |

Which signature a build needs (the reason is the DXMT updater: it installs
graphics only from an app it can verify as signed by the Cyder team):

| The build must… | Sign | Notarize |
|---|---|---|
| show windows and settings | ad-hoc | no |
| launch a game on this Mac | Developer ID | no |
| leave this Mac | Developer ID | yes |

## Traps that have cost time before

| Symptom | Cause | Do |
|---|---|---|
| A command that works in bash fails oddly | The shell is zsh (no word splitting, different globs, BSD tools) | Wrap bash syntax in `bash -c '…'`; avoid GNU-only flags |
| A `cmd1 && cmd2 && …` chain "did nothing" | An early step failed and the rest never ran | After any error, check what actually ran before continuing |
| A command acts on the wrong repo | The working directory moves between the two checkouts | Use absolute paths or `git -C <repo>` |
| Universal Swift link fails for x86_64 | `xcode-select` points at Command Line Tools | Prefix the build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Test build stops at `CYD-WIN-001`, log says `publisher_unverified` | Ad-hoc build cannot install graphics | Rebuild with `--sign-identity "Developer ID Application"`; do not weaken the check |
| Suite stops printing for minutes | A test opened a real alert or app | Stub `osascript` and `open` in that test |
| A test fails once | Could be load, focus, or a stale assertion | Rerun it alone three times and read the assertion before calling it flaky |
| Wrong archive ended up in the app | The app bundles every archive in the graphics folder; packers reuse old archives | Keep only what ships in that folder; repack with `--force` after a DXVK change |
| Settings show `1.4.2` / `1.2.10` | Those are **MoltenVK** versions | DXVK is always 1.10.3; DXMT is upstream 0.80 with a Developer ID signature |
| Long build hangs with no output | Checkout under `~/Documents`, `~/Desktop` or `~/Downloads` | Keep checkouts under `~/ogom` |

Fixed product facts: DXVK 2 is not shipped until it passes game testing.
0.14 / engine Cyder013 is the last line for macOS 10.15 and 11; later releases
need macOS 12+.

## Skills

Skills are in `.agents/skills/`. Claude Code does not load them automatically:
read the `SKILL.md` before starting that kind of work.

| Work | Skill |
|---|---|
| Tests, test builds, checking the real app | `cyder-dev-test` |
| Diagnosing or testing a game | `wine-game-compat-testing` |
| Building, notarizing, publishing a release | `cyder-release` |
| Checking a built `Cyder.app` or zip | `cyder-release-verify` |
| Wine engine work | `cyder-wine-engine-redirect` |

References: `docs/development-testing.md`, `docs/release-pipeline.zh-TW.md`,
`docs/release-signing.zh-TW.md`.

`AGENTS.md` is the only instruction file. `CLAUDE.md` is a one-line
`@AGENTS.md` import because Claude Code reads `CLAUDE.md`; add no other
per-tool files.
