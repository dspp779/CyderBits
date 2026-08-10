# Task 3 Report: bundled zstd resolution

## Status

Done.

## P1 follow-up

- `scripts/cyder-ensure-graphics.sh` now resolves zstd through a local
  `cyder_graphics_find_zstd` helper. It uses the same precedence as
  `cyder_find_zstd`: `CYDER_ZSTD`, bundled `CYDER_OGOM/tools/zstd/zstd`,
  script-adjacent `Resources/tools/zstd/zstd`, then `PATH`.
- The helper is local because `cyder-common.sh` sources
  `cyder-ensure-graphics.sh`; sourcing common back from this script would
  recurse.
- `tests/test-cyder-ensure-graphics.sh` unsets `CYDER_ZSTD`, constrains
  `PATH`, and exposes a fake bundled `Resources/tools/zstd/zstd`. It confirms
  both initial extraction and a DXVK payload update complete successfully.

## Verification

```text
bash -n scripts/cyder-ensure-graphics.sh tests/test-cyder-ensure-graphics.sh
bash tests/test-cyder-ensure-graphics.sh
bash tests/test-universal-zstd.sh
git diff --check

PASS test-cyder-ensure-graphics
PASS test-universal-zstd
```
