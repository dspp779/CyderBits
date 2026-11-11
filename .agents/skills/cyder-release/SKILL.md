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
2. Follow `.agents/skills/engine-release-pack` in the sibling `cyder-wine-engine` checkout
   (Developer ID, real graphics trees — never symlink `lib/dxvk` / `lib/dxmt`).
3. Import the packed engine into this repo. Also set
   `CYDER_GRAPHICS_ARTIFACTS_DIR` to the engine repo's `dist/artifacts/graphics`;
   importing the engine manifest does not import independent graphics archives.
   Require a signed `dxmt-0.80-cyder.N.tar.zst` revision, not legacy `dxmt-0.80`.
   Read `docs/graphics-signing-policy.zh-TW.md` for the current supported policy.

Import the engine:

```bash
bash scripts/import-engine-release.sh --manifest <path> --apply
```

4. Build, sign, notarize:

```bash
bash scripts/release-cyder.sh --channel release --version <semver>
```

5. **Must** run verify (fail-closed). `release-cyder.sh --channel release`
   already invokes verify after staple/zip (writes `Cyder.app.zip` and
   `Cyder-<version>.zip`; baseline = newest other `dist/Cyder-*.zip`).
   Re-run manually if needed:

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh \
  --app dist/Cyder.app \
  --zip dist/Cyder-0.13.1.zip \
  --baseline dist/Cyder-0.13.0.zip
```

   Emergency only: `RELEASE_SKIP_VERIFY=1` (do not use for shipping).

The App builder generates per-file manifests **after** graphics signing. Formal
builds verify DXMT provenance, original/final digests, Developer ID Team and secure
timestamp from the actual archive; ad-hoc/test output cannot substitute for this.
`--skip-notarization-checks` on verify does not disable native signature checks.
Do not auto-sign installed runtime files to make a diagnostic pass. A reviewed
legacy upstream-unsigned exception is diagnostic-only and cannot satisfy a new
formal release. Keep PE/Authenticode, macOS signing and antivirus acceptance separate.

6. On verify failure: **stop**. Do not publish the zip.
   - Undersized / symlink graphics → re-run graphics pack from a real engine tree,
     then re-run `release-cyder.sh`.
   - Gatekeeper / stapler → fix notarization, then re-verify.

## Same-version DXMT validation

Display DXMT upstream **0.80**; artifact/private signing identifiers can remain
separate provenance. Verify that the shipped manifest has `displayVersion` and
a digest/policy-derived `installKey`. Runtime installation must not use the
version marker as its only predicate. Test legacy unsigned and earlier signed
0.80 migration, digest/policy changes, healthy repeated launches, Windows-busy
and unknown evidence, prefix DLL repair, and rollback/interrupted transactions.
Run `tests/test-cyder-graphics-update.rb` and `tests/test-cyder-graphics-runtime.sh`.
A global barrier protects switching; do not disable it to make a build launch.
The end-user update is deferred until the next idle retry, not performed later
by an abandoned UI observation. Never claim the game was tested from a hash match.

## Re-release (graphics-only fix)

Skip unchanged engine rebuild if the pin is already correct, but still:

1. Pack real graphics in the engine repo with `--channel release --revision cyder.N`
   and exported Developer ID identity. Use a new revision for changed DXMT bytes;
   `--force` cannot overwrite an existing signed DXMT revision.
2. Re-run `release-cyder.sh --channel release` (auto-runs verify after zip).
3. If verify was skipped or you need a custom baseline, run `cyder-release-verify` manually.

## Related

- Verify only: `.agents/skills/cyder-release-verify`
- Engine redirect: `.agents/skills/cyder-wine-engine-redirect`
- Human pipeline: `docs/release-pipeline.zh-TW.md`
