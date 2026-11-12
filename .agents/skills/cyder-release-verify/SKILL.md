---
name: cyder-release-verify
description: >-
  Check a built Cyder.app or zip before or after notarization: graphics
  payloads, DXMT signature, no DXVK 2, engine label, zip size against the
  previous release, Gatekeeper and stapler. Use after a release build, a
  re-release, or when a zip looks too small.
---

# Cyder release verify

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh --app dist/Cyder.app --zip dist/Cyder-<version>.zip --baseline <previous release zip>
```

- Before notarization add `--skip-notarization-checks`. It skips only
  Gatekeeper and stapler; the DXMT signature check still runs.
- `--baseline` is optional. Without a previous zip, omit it and say the size
  comparison was not done.
- Non-zero exit: stop the release, fix the cause, rebuild. Do not edit the app
  or the installed runtime to make it pass.

`scripts/release-cyder.sh --channel release` runs this automatically after
stapling.

## What it checks

| Check | Passes when |
|---|---|
| DXVK payload | `graphics/dxvk-*.tar.zst` ≥ 2 MiB, real files (not a symlink), contains `d3d11.dll` |
| DXMT payload | The archive named by `dxmt-version.txt` is ≥ 8 MiB and contains `winemetal.so` |
| DXMT signature | `graphics-signing.py verify-archive` accepts provenance, file hashes, the Cyder Developer ID team and a secure timestamp. Version `0.80`; old `0.80-cyder.N` archives are still accepted |
| DXVK 2 | No `dxvk2` archive in the app and no `lib/dxvk2` in the engine |
| Engine | `engine-version.txt` is not empty and an `engine-*.tar.zst` exists |
| Size | Zip is no more than 1 MiB smaller than the baseline |
| Notarization | `spctl -a -vv` and `xcrun stapler validate` succeed |

Size limits can be overridden with `CYDER_VERIFY_DXVK_MIN_BYTES` and
`CYDER_VERIFY_DXMT_MIN_BYTES`.

Passing this script proves the package, not that a game runs.
