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

`components` is declarative only. The first implementation must resolve and
pin installers before running Winetricks. A recipe update never mutates an
existing bottle without an explicit migration/rebuild operation.
