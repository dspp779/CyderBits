# Agent instructions (Cyder / ogom)

This repository (CyderBits / ogom) owns the **application layer**: the Cyder
app, bottles, CompatDB, and game UX. It does **not** own the Wine engine that
actually runs Windows `.exe` files.

## Wine engine / incremental builds / patches

Do that work in **[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)**
(sibling checkout, often `/Users/jjc/cyder-wine-engine` or `../cyder-wine-engine`).

Before any wineserver / ntdll / host `make` / engine pack task:

1. Prefer opening that repo as the workspace.
2. Read `cyder-wine-engine/AGENTS.md`.
3. Read `cyder-wine-engine/docs/incremental-build-and-patches.md`.

Large trees (`build/`, `install/`, `tools/archives`, `.brew-x86`) may be
symlinks into `cyder-wine-engine`; still run build/pack scripts from the engine
repo so `.env` and scripts resolve correctly.

## Cyder.app release channels

- Test vs release (sign / notarize): `docs/release-pipeline.zh-TW.md`
- Wrapper: `bash scripts/release-cyder.sh --channel test|release`
- Signing credentials detail: `docs/release-signing.zh-TW.md`

## Multi-tool

| Tool | This repo | Engine repo |
|------|-----------|-------------|
| Codex / Cursor | `AGENTS.md` | `AGENTS.md` |
| Claude Code | `CLAUDE.md` | `CLAUDE.md` |
| Antigravity / Gemini | `GEMINI.md` | `GEMINI.md` + `.agents/skills/` |

Details: `cyder-wine-engine/docs/ai-agent-setup.md`.
