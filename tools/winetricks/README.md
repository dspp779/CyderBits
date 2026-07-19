# Bundled Winetricks

Cyder bundles the official Winetricks single-file script for the advanced
SharedPrefix integration.

- Upstream: https://github.com/Winetricks/winetricks
- Pinned source: `20260125/src/winetricks`
- Script SHA-256: `431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b`
- License: LGPL-2.1 (`COPYING`)

The script is launched with Cyder's `WINE`, `WINESERVER`, `WINEPREFIX`, and
`W_CACHE` environment variables. It must not be self-updated from inside the
app payload; update this directory intentionally when changing the pin.
