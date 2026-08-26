---
name: cyder-release-verify
description: >-
  Verify a built Cyder.app / Cyder.app.zip before or after notarization:
  graphics payload size and non-symlink contents, engine label/pin, zip size
  vs baseline, spctl and stapler. Use after release builds, re-releases, or
  when the app zip looks unexpectedly small.
---

# Cyder release verify

Run from ogom:

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh \
  --app dist/Cyder.app \
  --zip dist/Cyder.app.zip \
  --baseline dist/Cyder-0.13.0.zip
```

Before notarization checks: add `--skip-notarization-checks`.

Exit non-zero ⇒ stop the release; fix graphics pack or re-run `release-cyder.sh`.

`scripts/release-cyder.sh --channel release` calls this script automatically after
staple/zip (unless `RELEASE_SKIP_VERIFY=1`).

## Gates

- `graphics/dxvk-*.tar.zst` ≥ 2 MiB (override `CYDER_VERIFY_DXVK_MIN_BYTES`)
- `graphics/dxmt-*.tar.zst` ≥ 8 MiB (override `CYDER_VERIFY_DXMT_MIN_BYTES`)
- Archive top entry must not be a symlink (`tar -tv`); must contain `d3d11.dll` / `winemetal.so`
- Non-empty `engine-version.txt` and at least one `engine-*.tar.zst`
- Optional `--baseline`: zip size must be ≥ baseline − 1 MiB
- Unless `--skip-notarization-checks`: `spctl -a -vv` and `xcrun stapler validate`
