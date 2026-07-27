# Cyder game recipes

Recipes describe per-game defaults; they are data, not shell scripts. A recipe
must be safe to apply repeatedly and must not contain shell-evaluable command
strings. Installers and registry patches are interpreted by Cyder's future
profile backend after validation.

Required fields:

```json
{
  "id": "pikachu-volleyball",
  "revision": 1,
  "displayName": "皮卡丘排球",
  "baseTemplate": "recommended",
  "settings": { "dpi": 96, "retinaMode": false, "msync": false, "esync": false },
  "environment": {},
  "arguments": [],
  "components": []
}
```

`components` is declarative only. The offline recipe runner rejects recipes
that declare components until each installer has a pinned source, license
status, checksum, and re-entrant install procedure. This is why LF2 currently
produces a clear "not available offline" error instead of pretending to install
Winetricks packages.

The current framework can validate and plan recipes, apply settings to one
existing bottle, and provision the pinned cnc-ddraw renderer when a recipe
selects `settings.renderer: cnc-ddraw`:

```sh
scripts/cyder-recipe.sh validate recipes/defaults.json
scripts/cyder-recipe.sh plan recipes/defaults.json bluecg
scripts/cyder-recipe.sh apply recipes/defaults.json bluecg "$WINEPREFIX"
scripts/cyder-recipe.sh apply recipes/defaults.json richman-4 \
  "$WINEPREFIX" "/path/to/Richman 4/rich4.exe"
```

Applying writes `.cyder-recipe-settings.json` and, only after that operation
completes successfully, `.cyder-recipe-applied.json` inside the target bottle.
Recipe data is never executed as shell code. A recipe update never mutates an
existing bottle without an explicit migration/rebuild operation.

The cnc-ddraw installer verifies the bundled archive checksum, extracts only
`ddraw.dll`, `ddraw.ini`, and `Shaders/` beside the selected executable, and
refuses to overwrite unmanaged files. Its manifest records hashes so uninstall
removes only unchanged managed files. The matching CompatDB rule separately
selects `ddraw=n,b` for the target executable; copying the payload alone does
not change DLL policy for unrelated processes.
