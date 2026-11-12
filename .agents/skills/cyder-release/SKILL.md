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

## Which signing level

| Build | Sign | Notarize | Use |
|---|---|---|---|
| `--channel test` | ad-hoc | no | UI checks on this Mac only; cannot launch games |
| `--channel test --sign-identity "Developer ID Application"` | Developer ID | no | Launching games on this Mac; never hand it out |
| `--channel release` | Developer ID | yes, stapled | Anything a user downloads |

Notarize only the final candidate: every change to the app, the engine pin or
the graphics payloads after notarization means a full rebuild and a new
notarization, and the zip size and SHA-256 in the notes must be refreshed.
Docs-only changes (release notes, CHANGELOG) do not change the zip.
Day-to-day testing: `.agents/skills/cyder-dev-test`.

## Preflight (before step 4)

- `xcode-select -p` is Xcode, or prefix the build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Command Line Tools
  cannot link the Intel half of the universal `CyderSwift`.
- `security find-identity -v -p codesigning` lists the Developer ID identity,
  and `xcrun notarytool history --keychain-profile cyder-notary` works. If the
  profile is missing, create it per `docs/release-signing.zh-TW.md` (values come
  from `.env` and `auth/`; never print them).
- The graphics folder (`CYDER_GRAPHICS_ARTIFACTS_DIR`) holds exactly what ships:
  `dxvk-1.10.3.tar.zst` and the Developer ID signed `dxmt-0.80.tar.zst`. The app
  bundles every archive found there, so move legacy unsigned DXMT, old
  `cyder.N` archives and any `dxvk2-*` aside (do not delete).
- DXVK archives are reused unless repacked with `--force`; after a DXVK patch,
  confirm the archive was rebuilt.
- macOS floor of the engine: check the versioned MoltenVK files with
  `otool -l … | grep -A3 LC_BUILD_VERSION`. A from-scratch build with a current
  Xcode SDK cannot target below macOS 12; 0.14 / Cyder013 is the last line that
  supports macOS 10.15/11 and reuses Cyder012's MoltenVK 1.2.10 for that.
- Full offline suite passes (`bash tests/run.sh`), and at least one real game
  was launched from a Developer ID signed build of this exact tree. If not,
  say so in the notes' known issues and in the report.
- Move the previous attempt's outputs to `dist/superseded-<date>-<reason>/`
  instead of deleting them.

## Checklist

0. Write the release notes by `docs/release-notes-guide.md`: `docs/releases/vX.Y.Z.md`
   (and `.en.md`), the `CHANGELOG.md` entry and the `docs/README.md` release row, in
   one change. Fill sizes and SHA-256 from the final notarized zip only.

1. Read `config/cyder-app-version.txt`. For `--channel release` require a clean
   semver (no `-dev` / branch suffix unless the user explicitly overrides).
2. Follow `.agents/skills/engine-release-pack` in the sibling `cyder-wine-engine` checkout
   (Developer ID, real graphics trees — never symlink `lib/dxvk` / `lib/dxmt`).
3. Import the packed engine into this repo. Also set
   `CYDER_GRAPHICS_ARTIFACTS_DIR` to the engine repo's `dist/artifacts/graphics`;
   importing the engine manifest does not import independent graphics archives.
   Require a Developer ID signed `dxmt-0.80.tar.zst` (verified by signature and
   provenance — the legacy unsigned archive has the same name).
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
  --zip dist/Cyder-<version>.zip \
  --baseline dist/Cyder-<previous-version>.zip
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

7. Publish only when the user asks (tagging, pushing and a GitHub release are
   outward-facing). Then, in order:
   - notes, `CHANGELOG.md` and `docs/README.md` carry the final zip size and
     SHA-256; `dist/SHA256SUMS.txt` is regenerated from the final zip;
   - merge to `main` and push both repos; tag `vX.Y.Z` on Cyderbits `main`
     (the compare link in the notes works only after the tag exists);
   - `gh release view vX.Y.Z` first: an old draft may hold stale assets or
     point at an old commit. Replace its assets with `Cyder-<version>.zip` and
     `SHA256SUMS.txt`; the body is the zh-TW notes with a download section on
     top (same style as the previous release) and a link to the English notes;
   - download the published zip back and run `shasum -a 256 -c`; open the
     English-notes and compare links.

## DXVK 2 and DXMT naming

- DXVK 2 is not shipped until it has passed game testing. `create-cyder-app.sh`
  and `cyder-release-verify` reject any `dxvk2` payload; lifting that is a
  deliberate code change with test results, not a packaging tweak.
- DXMT keeps the upstream version (`0.80`, `dxmt-0.80.tar.zst`). Cyder only adds
  a Developer ID signature to `winemetal.so`; it does not modify DXMT, so no
  `cyder.N` suffix is produced and release notes say "DXMT 0.80 (upstream,
  Developer ID signed)". Re-sign only when upstream DXMT or the signing policy
  changes. In Settings, `1.4.2` / `1.2.10` are **MoltenVK** versions; DXVK is
  always 1.10.3.

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

1. Pack real graphics in the engine repo with `--channel release` and exported
   Developer ID identity. Unchanged upstream DXMT reuses the existing signed
   `dxmt-0.80.tar.zst`; `--force` never overwrites it. Re-sign only when the
   upstream source or signing policy changes, after moving the old archive aside.
2. Re-run `release-cyder.sh --channel release` (auto-runs verify after zip).
3. If verify was skipped or you need a custom baseline, run `cyder-release-verify` manually.

## Related

- Verify only: `.agents/skills/cyder-release-verify`
- Engine redirect: `.agents/skills/cyder-wine-engine-redirect`
- Human pipeline: `docs/release-pipeline.zh-TW.md`
