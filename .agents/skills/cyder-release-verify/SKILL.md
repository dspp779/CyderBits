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
- Select the active archive from `dxmt-version.txt`, not an arbitrary old glob match.
- DXMT must use `0.80-cyder.N` and pass `graphics-signing.py verify-archive`:
  provenance, complete file set/hashes, reviewed upstream digests, expected
  Developer ID Team and secure timestamp. This gate remains enabled with
  `--skip-notarization-checks`. Missing proof stops release; do not auto-repair.
- Legacy upstream unsigned bytes can be reported accurately by diagnostics,
  but are not accepted as a newly signed formal graphics release.
- Non-empty `engine-version.txt` and at least one `engine-*.tar.zst`
- Optional `--baseline`: zip size must be ≥ baseline − 1 MiB
- Unless `--skip-notarization-checks`: `spctl -a -vv` and `xcrun stapler validate`

## Digest-managed DXMT test builds

Check displayed DXMT version **0.80**, not the private artifact revision. The
manifest `installKey` must bind artifact digest and signature policy. For runtime
acceptance, use an isolated runtime through the native global update guard;
confirm repeated updates are no-ops and do not touch existing user prefixes.
Busy, unreadable process inventory, unknown signature verification, and an
unfinished transaction must defer without switching links or prefix DLLs.
Include the Ruby updater and native runtime-guard offline suites. After ZIP
round-trip, recheck publisher trust and the active digest object's full manifest.
Do not replace this with a version-marker-only check or a manual in-place copy.
