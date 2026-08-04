# Dual font replacements design

Status: implemented (0.9.4 ships the narrowed option set below).

## Summary

Two independent Wine `Fonts\Replacements` targets:

1. **細明體取代**（`fontMingLiuTarget`）— MingLiU family + shell dialog faces
2. **宋體取代**（`fontSongtiTarget`）— SimSun / 宋体 family

## Options (shipped)

| ID | UI | Face | Notes |
|----|----|------|-------|
| `mingliu` | 細明體 | `MingLiU` | MingLiU family + this id → **delete** replacement keys |
| `songti` | 宋體 | `Songti TC` | macOS built-in; Songti family still **writes** even when id is `songti` |
| `pingfang` | 蘋方 | `PingFang TC` | macOS built-in |

Invalid / retired ids (`jhenghei`, `lihei`, `ligothic`, `lantinghei`, `heiti`, …) sanitize to the field fallback.

## Defaults (related)

- `retinaMode` default **false**; DPI default **96**
- `graphicsHud` default **off**; reset-all must rebuild HUD menu to 關閉 before save
