# Release notes guide

How Cyder writes release notes (`docs/releases/vX.Y.Z.md`, plus `vX.Y.Z.en.md` for
English) and the root [`CHANGELOG.md`](../CHANGELOG.md). [v0.14.0](releases/v0.14.0.md)
is the reference example.

## What we borrowed, and from where

| Project | What we take from it |
|---|---|
| [Wine](https://gitlab.winehq.org/wine/wine) (`ANNOUNCE`) | A short "what's new" summary first; link Wine bugs by number (`bugs.winehq.org`); credit upstream commits by hash. |
| [CrossOver changelog](https://www.codeweavers.com/crossover/changelog) | Group by area; one terse bullet per game fix; state component versions as plain facts (Wine, DXVK, MoltenVK, DXMT, D3DMetal). |
| [DXVK releases](https://github.com/doitsujin/dxvk/releases) | A dedicated game-fixes list with the **game name in bold**; requirement changes in their own clearly marked section; links to PRs. |
| [GE-Proton releases](https://github.com/GloriousEggroll/proton-ge-custom/releases) | A component-versions section; say where a fix came from (upstream, GE-Proton, ours); thank contributors. |
| [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) | `CHANGELOG.md` uses Added / Changed / Deprecated / Removed / Fixed / Security, newest first, with compare links. |

## Release notes layout

1. **Title and summary table**: release date, engine label and its base
   (CrossOver FOSS version, Wine version), supported macOS. Link the other
   language and the GitHub compare view. Signing and notarization are standard
   for every release and are not repeated here.
2. **Important callout** (`> [!IMPORTANT]`) only for things a user must act on or
   know before upgrading: dropped macOS versions, data migrations.
3. **Highlights**: up to six bullets a player cares about, each with its PR link
   where one exists. Compare against the previous release's actual behavior, not
   an assumption. No internal terms.
4. **Game fixes**, right after the highlights: `**Game:** what was wrong, why, and
   what changed (link)`. Name the hardware or macOS limits of a fix.
5. **New features and improvements**, grouped by area (Lifecycle, Graphics,
   DirectDraw, Scrolling, Settings and UI, Diagnostics and security). When a fix's
   cause is not obvious, explain it in one or two plain sentences. Introduce a
   bundled third-party component with a link and what it does for the player.
   Skip anything that happens automatically and needs no action.
6. **Engine changes**: a table of change and origin (Cyder, upstream Wine backport,
   GE-Proton, CrossOver), each with its engine PR.
7. **Component versions**: Wine/CrossOver, engine archive and SHA-256, DXVK,
   MoltenVK, DXMT, cnc-ddraw, and anything deliberately not included.
8. **Known issues**: honest limits, including what has not been tested on real
   hardware. Do not claim performance gains that were not measured.
9. **Download and verification**: file, size, SHA-256, and the `shasum` command.
10. **Acknowledgements**: upstream projects with links, and reporters.

## Style

- Lead each bullet with the user-visible effect in bold, then the cause in plain words.
- Link every claim that has one: PR, issue, Wine bug, upstream commit.
- Say where a fix comes from; never present an upstream fix as our own.
- Keep implementation detail (file names, internal flags) out of the highlights;
  it belongs in the engine table or the linked PR.
- Numbers (sizes, hashes, timings) come from the actual release build, never estimates.
- Update `CHANGELOG.md` and the release table in [`docs/README.md`](README.md) in the
  same change as the release notes.
