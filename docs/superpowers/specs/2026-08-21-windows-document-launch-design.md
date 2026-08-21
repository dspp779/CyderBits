# Windows document launch: `.bat` / `.cmd` / `.lnk` / `.reg`

> Status: approved for Cyder **0.13.0** (Approach B — kind-specific launch)  
> Date: 2026-08-21

## Goal

Let Finder / `open` hand Windows-specific documents to Cyder the same way as
`.exe` and `.msi`, with correct working directory and visible failure when the
prefix cannot accept the action.

## Non-goals (0.13.0)

- Auto-add `.bat` / `.lnk` tiles to the game library
- Thin macOS launchers that embed `.bat` / `.lnk` / `.reg`
- Full Shell Link parser for every optional field (Unicode LocalBasePathUnicode,
  environment blocks, etc.)
- PowerShell / VBS / JS

## Approach B

| Kind | Extensions | Wine invocation | cwd | Busy prefix |
|------|------------|-----------------|-----|-------------|
| script | `.bat`, `.cmd` | `cmd /c` with the script path (quoted); extra argv after `/c` if provided | directory of the script (existing `cd "$(dirname …)"`) | allowed (like `.exe`) |
| link | `.lnk` | `start /wait /unix` so Wine resolves WorkingDir / args | directory of the `.lnk` (Wine may still honor link WorkingDir) | allowed |
| reg | `.reg` | `regedit /s` quiet import | directory of the `.reg` | **refuse** (exit 75), same policy as MSI |

Profile bottles: script / link use the same profile resolution as `.exe` when the
path maps to a profile id; `.reg` always targets the shared prefix (installer-like).

## Surfaces

1. `Info.plist` document types + UTImportedTypeDeclarations as needed  
2. `normalizeLaunchablePaths` (rename/extend `normalizeExePaths`) accepts the new extensions  
3. `CyderWineLaunchTarget`: `exe | msi | script | link | reg`  
4. `cyder_launcher.sh`: `--launch-script`, `--launch-lnk`, `--launch-reg`  
5. `cyder_run_wine_exe` / `CYDER_LAUNCH_TARGET_KIND`: `exe | msi | script | link | reg`  
6. `cyder-macos-wrapper.sh`: route by extension like MSI  
7. Docs: `docs/cyder.md`, `docs/releases/v0.13.0.md`

## Error UX

- Invalid / unreadable path → existing validation failure alerts  
- `.reg` while shared prefix busy → alert + exit 75  
- Launch failures → existing wine / silent-exit alert paths

## Testing

Contract tests for: path filter extensions, plist extensions, launcher flags,
wrapper routing, and busy-reg policy string. No full Wine integration required
for CI.
