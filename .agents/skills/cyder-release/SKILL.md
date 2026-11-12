---
name: cyder-release
description: >-
  Ship a Cyder release end to end: release notes, Developer ID engine and
  graphics pack, engine import, `release-cyder.sh --channel release`
  (sign, notarize, staple, verify), and publishing to GitHub. Use when cutting
  a version, notarizing Cyder.app, re-releasing after a failed check, or
  publishing a release.
---

# Cyder release

Do the steps in order. Stop when a step fails; never publish a zip that did
not pass step 6. References: `docs/release-pipeline.zh-TW.md`,
`docs/release-signing.zh-TW.md`, `docs/graphics-signing-policy.zh-TW.md`.

## 1. Preflight

1. `config/cyder-app-version.txt` holds a clean version (no `-dev`).
2. Signing works:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

```bash
xcrun notarytool history --keychain-profile cyder-notary
```

   If the profile is missing, create it per `docs/release-signing.zh-TW.md`.
   Values come from `.env` and `auth/`; never print them.
3. `xcode-select -p` is Xcode. Otherwise prefix every build command with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line
   Tools cannot link the Intel half of the app).
4. `bash tests/run.sh` passes.
5. A real game was launched from a Developer ID signed build of this tree
   (skill `cyder-dev-test`). If not, write "not game-tested" in the notes'
   known issues and in your report.

## 2. Pack the engine and graphics (engine repo)

Follow `engine-release-pack` in `../cyder-wine-engine`. Skip the engine rebuild
only when the pin is already the engine you intend to ship. Then check the
result, because packers reuse what is already on disk:

1. `dist/artifacts/graphics/` in the engine repo holds **only**
   `dxvk-1.10.3.tar.zst` and the Developer ID signed `dxmt-0.80.tar.zst` (plus
   their version and checksum files). The app bundles every archive in that
   folder, so move anything else aside: `dxvk2-*`, old `cyder.N` archives, a
   legacy unsigned DXMT. Do not delete; move to `…-superseded-<reason>/`.
2. After any DXVK source or patch change, repack DXVK with `--force` and
   confirm the archive is new. A reused archive silently ships the old DXVK.
3. Signed DXMT is reused, never overwritten. Re-sign only when upstream DXMT or
   the signing policy changes, after moving the old archive aside.
4. Check the macOS floor of both MoltenVK files in the packed engine with
   `otool -l <file> | grep -A3 LC_BUILD_VERSION`. A from-scratch build with a
   current Xcode SDK cannot target below macOS 12.

## 3. Import the engine

```bash
bash scripts/import-engine-release.sh --manifest <engine archive>.manifest.json --apply
```

Without `--apply` it only verifies. Importing does not copy graphics:
`CYDER_GRAPHICS_ARTIFACTS_DIR` (default `dist/artifacts/graphics`, a link to
the engine repo) is read at build time.

## 4. Write the notes

Follow `docs/release-notes-guide.md`: `docs/releases/vX.Y.Z.md` and `.en.md`,
`CHANGELOG.md`, and the row in `docs/README.md`, in one change.

- Describe the previous release's **actual** behaviour; check it in the code or
  the old notes instead of assuming.
- List only components that are in the build. DXVK 2 is not shipped. DXMT is
  "0.80 (upstream, Developer ID signed)".
- Leave size and SHA-256 blank until step 6 has passed.

## 5. Build, sign, notarize

```bash
bash scripts/release-cyder.sh --channel release
```

Move a previous attempt's outputs to `dist/superseded-<date>-<reason>/` first.
The script signs with Developer ID, notarizes, staples, writes
`dist/Cyder.app.zip` and `dist/Cyder-<version>.zip`, and runs the verify script.

Notarize only the final candidate. Any later change to the app, the engine pin
or the graphics folder means repeating this step and step 6. Notes and
CHANGELOG edits do not change the zip.

## 6. Verify

`release-cyder.sh` already ran it. To rerun:

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh --app dist/Cyder.app --zip dist/Cyder-<version>.zip --baseline <previous release zip>
```

On failure, stop and fix the cause:

| Failure | Fix |
|---|---|
| Graphics archive too small or a symlink | Repack graphics from a real engine tree (step 2), rebuild |
| DXMT signature or provenance | Put the signed `dxmt-0.80.tar.zst` in the graphics folder; never ad-hoc sign or sign installed files |
| `dxvk2` found | Remove it from the graphics folder; lifting the block needs game-test results and a code change |
| Gatekeeper or stapler | Fix notarization (`notarytool log <id>`), rebuild |

`RELEASE_SKIP_VERIFY=1` is for emergencies, never for a shipped build.

After it passes: fill the size and SHA-256 into the notes from the final zip
and regenerate `dist/SHA256SUMS.txt`.

## 7. Publish (only when the user asks)

1. Commit, merge both repos to `main`, push.
2. Tag `vX.Y.Z` on Cyderbits `main` and push the tag. The compare link in the
   notes works only after this.
3. `gh release view vX.Y.Z`: if a draft exists, check its assets and target
   commit; an old draft carries a stale zip. Upload `Cyder-<version>.zip` and
   `SHA256SUMS.txt`, replacing anything else.
4. Body: the zh-TW notes with a download section on top (copy the previous
   release's layout) and a link to the English notes.
5. Download the published zip and run `shasum -a 256 -c SHA256SUMS.txt`. Open
   the English-notes and compare links.

## Same-version DXMT changes

When the DXMT archive changes without a version change (new signature or
policy), the app must treat it as an update. The manifest's `installKey` binds
the archive digest and signing policy; the version marker alone is not the
predicate. Run `tests/test-cyder-graphics-update.rb` and
`tests/test-cyder-graphics-runtime.sh`, and read
`docs/dxmt-digest-update.zh-TW.md`. Never disable the update guard, overwrite
installed files by hand, or force-quit games to make a build launch.
