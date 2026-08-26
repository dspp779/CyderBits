---
name: cyder-release
description: >-
  Orchestrate a Cyder formal release: engine Developer ID pack, import pin,
  `release-cyder.sh --channel release`, then `cyder-release-verify`. Use when
  cutting a shipping version, notarizing Cyder.app, or re-releasing after a
  failed zip/graphics check.
---

# Cyder formal release

Orchestrate the shipping channel end-to-end. Do **not** skip verify.

## Checklist

1. Read `config/cyder-app-version.txt`. For `--channel release` require a clean
   semver (no `-dev` / branch suffix unless the user explicitly overrides).
2. Follow `.agents/skills/engine-release-pack` in `/Users/jjc/cyder-wine-engine`
   (Developer ID, real graphics trees — never symlink `lib/dxvk` / `lib/dxmt`).
3. Import the packed engine into this repo:

```bash
bash scripts/import-engine-release.sh --manifest <path> --apply
```

4. Build, sign, notarize:

```bash
bash scripts/release-cyder.sh --channel release --version <semver>
```

5. **Must** run verify (fail-closed):

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh \
  --app dist/Cyder.app \
  --zip dist/Cyder.app.zip \
  --baseline dist/Cyder-0.13.0.zip   # or next-newest Cyder-*.zip
```

6. On verify failure: **stop**. Do not publish the zip.
   - Undersized / symlink graphics → re-run graphics pack from a real engine tree,
     then re-run `release-cyder.sh`.
   - Gatekeeper / stapler → fix notarization, then re-verify.

## Re-release (graphics-only fix)

Skip unchanged engine rebuild if the pin is already correct, but still:

1. Pack real graphics in the engine repo (`pack-graphics-payloads.sh --force`).
2. Re-run `release-cyder.sh --channel release`.
3. Run `cyder-release-verify` again.

## Related

- Verify only: `.agents/skills/cyder-release-verify`
- Engine redirect: `.agents/skills/cyder-wine-engine-redirect`
- Human pipeline: `docs/release-pipeline.zh-TW.md`
