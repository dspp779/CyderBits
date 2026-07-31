# Agent instructions (Cyder / ogom)

This repository owns the Cyder app, bottles, CompatDB, and game UX. It does
**not** own the Wine engine build pipeline.

## Wine engine / incremental builds / patches

Do that work in the sibling checkout **`cyder-wine-engine`** (often
`/Users/jjc/cyder-wine-engine` or `../cyder-wine-engine`).

Before any wineserver / ntdll / host `make` / engine pack task:

1. Prefer opening that repo as the workspace.
2. Read `cyder-wine-engine/AGENTS.md`.
3. Read `cyder-wine-engine/docs/incremental-build-and-patches.md`.

Large trees (`build/`, `install/`, `tools/archives`, `.brew-x86`) may be
symlinks into `cyder-wine-engine`; still run build/pack scripts from the engine
repo so `.env` and scripts resolve correctly.

## Multi-tool

| Tool | This repo | Engine repo |
|------|-----------|-------------|
| Codex / Cursor | `AGENTS.md` | `AGENTS.md` |
| Claude Code | `CLAUDE.md` | `CLAUDE.md` |
| Antigravity / Gemini | `GEMINI.md` | `GEMINI.md` + `.agents/skills/` |

Details: `cyder-wine-engine/docs/ai-agent-setup.md`.
