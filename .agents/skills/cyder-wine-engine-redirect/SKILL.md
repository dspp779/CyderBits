---
name: cyder-wine-engine-redirect
description: >-
  Redirect Wine engine, wineserver, ntdll, minOS, and pack work to the
  cyder-wine-engine sibling repository. Use when the user asks about Wine
  engine builds, patches, or packing from the Cyder app repo.
---

# Use cyder-wine-engine for engine work

This Cyder (ogom) repo does not own the Wine build. For incremental builds,
patches, host minOS, or `pack-engine-artifact`:

1. Work in `../cyder-wine-engine` (or `/Users/jjc/cyder-wine-engine`).
2. Read that repo’s `AGENTS.md` and `docs/incremental-build-and-patches.md`.
3. Prefer its `.agents/skills/incremental-wine-build` skill when available.
