---
name: cyder-wine-engine-redirect
description: >-
  Send Wine engine work (wineserver, ntdll, Wine patches, host builds, minOS,
  MoltenVK, engine or graphics packing) to the cyder-wine-engine sibling repo.
  Use when such a task is asked from the CyderBits repo.
---

# Engine work belongs in cyder-wine-engine

CyderBits does not build Wine. For any engine task:

1. Work in `../cyder-wine-engine` (`~/ogom/cyder-wine-engine`). Run its scripts
   from there so its `.env` and paths apply.
2. Read its `AGENTS.md`, then the skill for the task:

| Task | Skill in the engine repo |
|---|---|
| Build, patch, rebuild ntdll or wineserver, direct engine tests | `.agents/skills/incremental-wine-build` |
| Developer ID engine and graphics pack for a release | `.agents/skills/engine-release-pack` |

3. Come back to CyderBits for what follows:

| Next step | Skill here |
|---|---|
| Import the packed engine, notarize, publish | `cyder-release` |
| Check a built app | `cyder-release-verify` |
| Try the engine in Cyder.app or with a game | `cyder-dev-test` |

Use absolute paths or `git -C <repo>` when a command must hit a specific
checkout: the working directory can change between the two.
