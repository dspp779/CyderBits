# Agent instructions (Cyder / ogom)

This repository (CyderBits / ogom) owns the **application layer**: the Cyder
app, bottles, CompatDB, and game UX. It does **not** own the Wine engine that
actually runs Windows `.exe` files.

## Wine engine / incremental builds / patches

Do that work in **[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)**
(sibling checkout, often `~/ogom/cyder-wine-engine` or `../cyder-wine-engine`).

Before any wineserver / ntdll / host `make` / engine pack task:

1. Prefer opening that repo as the workspace.
2. Read `cyder-wine-engine/AGENTS.md`.
3. Read `cyder-wine-engine/docs/incremental-build-and-patches.md`.

Large trees (`build/`, `install/`, `tools/archives`, `.brew-x86`) may be
symlinks into `cyder-wine-engine`; still run build/pack scripts from the engine
repo so `.env` and scripts resolve correctly.

## Everyday development

Full guide: `docs/development-testing.md`. Skill: `.agents/skills/cyder-dev-test`.

- **Tests:** `bash tests/run.sh` (whole suite, about 12 minutes; run it in the
  background) or `bash tests/run.sh <word>` for tests whose name contains a
  word. Add or extend the narrowest `tests/test-*` with every behaviour change.
- **Test build:** `bash scripts/release-cyder.sh --channel test --out-dir <dir outside dist/>`;
  prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when
  the universal Swift link fails.
- **Signing level:** ad-hoc for UI checks only; Developer ID
  (`--sign-identity "Developer ID Application"`, not notarized) to launch a
  game on this Mac; notarized (`--channel release`) for anything that leaves
  this Mac. Ad-hoc builds cannot launch games by design.
- **Real app:** a test build shares the user's real settings and Windows
  environment; do not run 修復／完全重設 or change game options unless asked.
- **Games:** `.agents/skills/wine-game-compat-testing`, plus the per-game steps
  in `docs/games/<game>/testing.md` (BlueCG: `docs/games/bluecg/testing.md`).
- **Claims:** a passing suite, a hash match or a notarized zip is not a game
  test. Report what was not tested.
- **Git:** work on a `claude/<topic>` branch; merge, push, tag and publish only
  when the user asks. Never commit `.local/`, `.research/`, `.tmp-*/`, `auth/`
  or `.env`.
- **Docs:** user-facing docs are zh-TW; agent and process guides are English.
  When a session teaches something reusable, update the matching doc or skill
  in the same change.

## Cyder.app release channels

- Test vs release (sign / notarize): `docs/release-pipeline.zh-TW.md`
- Wrapper: `bash scripts/release-cyder.sh --channel test|release`
- Signing credentials detail: `docs/release-signing.zh-TW.md`
- Formal release: `.agents/skills/cyder-release` (preflight, notarize, verify,
  publish); notes format: `docs/release-notes-guide.md`
- Not shipped until game-tested: DXVK 2. DXMT keeps the upstream version
  (`0.80`); Cyder only adds a Developer ID signature.
- 0.14 / engine Cyder013 is the last line for macOS 10.15 and 11; later
  releases need macOS 12+.

## Skills

Skills live in `.agents/skills/`. Tools that do not load them automatically
(Claude Code) should read the matching `SKILL.md` before that kind of work:

| When | Read |
|------|------|
| Running tests, test builds, checking the real app or a game | `.agents/skills/cyder-dev-test/SKILL.md` |
| Diagnosing a game (backend, video, launcher chain) | `.agents/skills/wine-game-compat-testing/SKILL.md` |
| Cutting, notarizing or publishing a release | `.agents/skills/cyder-release/SKILL.md` |
| Checking a built `Cyder.app` / zip | `.agents/skills/cyder-release-verify/SKILL.md` |
| Anything about the Wine engine | `.agents/skills/cyder-wine-engine-redirect/SKILL.md` |

## Entry files

`AGENTS.md` is the single source of instructions in both repos. `CLAUDE.md` is
a one-line `@AGENTS.md` import, kept only because Claude Code reads `CLAUDE.md`
and not `AGENTS.md`. Do not add other per-tool files; put rules here.
