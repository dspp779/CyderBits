# Cyder Release Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four coordinated agent skills plus executable verify/gates so formal Cyder releases cannot silently ship symlink-stub graphics payloads or skip post-build acceptance checks.

**Architecture:** `cyder-release` (ogom) orchestrates; `engine-release-pack` (cyder-wine-engine) produces Developer ID engine + real graphics; `cyder-release-verify` (ogom) fail-closes on size/content/Gatekeeper; hard gates in `pack-graphics-payloads.sh` reject symlink sources. Existing incremental-build and redirect skills get thin pointers only.

**Tech Stack:** Bash skills under `.agents/skills/`, existing `tests/assert.sh` harnesses, `pack-graphics-payloads.sh` / `release-cyder.sh` / `import-engine-release.sh`, zstd + tar for archive inspection.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-26-cyder-release-skills-design.md` (approved).
- No Cursor Marketplace plugin; skills live in each repo’s `.agents/skills/`.
- Never commit signing secrets or notary credentials into skills.
- Graphics source dirs must not be symlinks; packed `dxvk-*.tar.zst` ≥ 2 MiB and `dxmt-*.tar.zst` ≥ 8 MiB for release verify (unit tests may use smaller fakes with env overrides where noted).
- `pack-graphics-payloads.sh` source of truth for packing is **cyder-wine-engine**; if ogom still has a copy/symlink, keep behavior aligned or document the pointer.
- Conventional Commits; do not commit unless the user asks (plan steps show suggested messages for when approved).
- Work in the correct repo for each task; use absolute paths `/Users/jjc/ogom` and `/Users/jjc/cyder-wine-engine`.

## File map

| File | Responsibility |
|------|----------------|
| `ogom/.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh` | Executable acceptance checks |
| `ogom/.agents/skills/cyder-release-verify/SKILL.md` | When/how to run verify |
| `ogom/tests/test-cyder-release-verify.sh` | Contract + fixture tests for verify script |
| `cyder-wine-engine/scripts/pack-graphics-payloads.sh` | Reject symlink `lib/dxvk|dxvk2|dxmt`; min output size |
| `cyder-wine-engine/tests/test-pack-graphics-payloads.sh` | Extend for symlink refusal |
| `cyder-wine-engine/.agents/skills/engine-release-pack/SKILL.md` | Formal engine pack runbook for agents |
| `ogom/.agents/skills/cyder-release/SKILL.md` | Full release orchestration |
| `ogom/.agents/skills/cyder-wine-engine-redirect/SKILL.md` | Point to formal pack/release |
| `cyder-wine-engine/.agents/skills/incremental-wine-build/SKILL.md` | Point formal pack to engine-release-pack |
| `ogom/docs/release-pipeline.zh-TW.md` | Human index → skills |
| `cyder-wine-engine/docs/ai-agent-setup.md` | Register new engine skill |

---

### Task 1: `verify-cyder-release.sh` + tests (ogom)

**Files:**
- Create: `ogom/.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh`
- Create: `ogom/tests/test-cyder-release-verify.sh`
- Create: `ogom/.agents/skills/cyder-release-verify/SKILL.md` (minimal stub OK here; Task 4 expands prose if needed — prefer full SKILL in this task)

**Interfaces:**
- Produces: CLI

```bash
verify-cyder-release.sh --app PATH --zip PATH [--baseline PATH] [--skip-notarization-checks]
# exit 0 = pass; non-zero = fail with messages on stderr
```

- Env overrides for tests only: `CYDER_VERIFY_DXVK_MIN_BYTES` (default `2097152`), `CYDER_VERIFY_DXMT_MIN_BYTES` (default `8388608`).

- [ ] **Step 1: Write failing test**

Create `tests/test-cyder-release-verify.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
VERIFY="$ROOT/.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh"

assert test -f "$VERIFY"
assert_contains "$(cat "$VERIFY")" 'CYDER_VERIFY_DXVK_MIN_BYTES'
assert_contains "$(cat "$VERIFY")" 'tar -tv'
assert_contains "$(cat "$VERIFY")" 'skip-notarization-checks'

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-release-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Minimal fake app + zip with stub graphics (tiny zstd of a symlink-like tree)
mkdir -p "$tmp/Cyder.app/Contents/Resources/graphics"
# Build a tiny zstd that tar-lists as a symlink entry (reproduces the bug class)
mkdir -p "$tmp/stage"
ln -s /tmp/nonexistent-dxvk "$tmp/stage/dxvk"
# Prefer project zstd if present
ZSTD="${CYDER_ZSTD:-$(command -v zstd)}"
[[ -x "$ROOT/tools/zstd/zstd" ]] && ZSTD="$ROOT/tools/zstd/zstd"
( cd "$tmp/stage" && tar -cf - dxvk | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxvk-1.10.3.tar.zst" )
# dxmt missing → also fail; add tiny real-ish file below min
printf 'not-a-real-payload' | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxmt-0.80.tar.zst"
printf 'CX26.3.0-W11-Cyder012\n' >"$tmp/Cyder.app/Contents/Resources/engine-version.txt"
: >"$tmp/Cyder.app/Contents/Resources/engine-CX26-3-0-W11-Cyder012.tar.zst"
mkdir -p "$ROOT/config"
# pin file may already exist; script should read ROOT/config when --pin omitted —
# for fixture, pass engine label via file next to app only.

# Zip the fake app
( cd "$tmp" && zip -qr Cyder.app.zip Cyder.app )

# Expect failure (graphics too small / symlink tar)
set +e
CYDER_VERIFY_DXVK_MIN_BYTES=100 CYDER_VERIFY_DXMT_MIN_BYTES=100 \
  bash "$VERIFY" --app "$tmp/Cyder.app" --zip "$tmp/Cyder.app.zip" \
  --skip-notarization-checks --baseline "$tmp/Cyder.app.zip"
status=$?
set -e
assert_ne "$status" "0" "symlink/tiny graphics must fail verify"

# Good graphics: directory of files (not symlink) above min bytes
rm -rf "$tmp/stage" "$tmp/Cyder.app/Contents/Resources/graphics"
mkdir -p "$tmp/stage/dxvk/x86_64-windows" "$tmp/stage/dxmt/x86_64-unix"
dd if=/dev/zero of="$tmp/stage/dxvk/x86_64-windows/d3d11.dll" bs=1024 count=64 status=none
dd if=/dev/zero of="$tmp/stage/dxmt/x86_64-unix/winemetal.so" bs=1024 count=64 status=none
mkdir -p "$tmp/Cyder.app/Contents/Resources/graphics"
( cd "$tmp/stage" && tar -cf - dxvk | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxvk-1.10.3.tar.zst" )
( cd "$tmp/stage" && tar -cf - dxmt | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxmt-0.80.tar.zst" )
printf 'CX26.3.0-W11-Cyder012\n' >"$tmp/Cyder.app/Contents/Resources/engine-version.txt"
dd if=/dev/zero of="$tmp/Cyder.app/Contents/Resources/engine-CX26-3-0-W11-Cyder012.tar.zst" bs=1024 count=8 status=none
( cd "$tmp" && rm -f Cyder.app.zip && zip -qr Cyder.app.zip Cyder.app )

CYDER_VERIFY_DXVK_MIN_BYTES=1000 CYDER_VERIFY_DXMT_MIN_BYTES=1000 \
  bash "$VERIFY" --app "$tmp/Cyder.app" --zip "$tmp/Cyder.app.zip" \
  --skip-notarization-checks --baseline "$tmp/Cyder.app.zip"
assert_eq "$?" "0" "valid fake payloads must pass verify when notarization skipped"

echo "PASS test-cyder-release-verify"
```

Fix `assert_ne` if the harness lacks it — use:

```bash
if [[ "$status" -eq 0 ]]; then echo "ASSERT failed: expected non-zero" >&2; exit 1; fi
```

- [ ] **Step 2: Run test — expect FAIL** (missing script)

Run: `bash /Users/jjc/ogom/tests/test-cyder-release-verify.sh`  
Expected: FAIL (`No such file` or assert `test -f` fails)

- [ ] **Step 3: Implement `verify-cyder-release.sh`**

Implement at `.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh`:

- Parse `--app`, `--zip`, `--baseline`, `--skip-notarization-checks`.
- Require at least one of `--app` / `--zip`. If only zip, extract graphics/engine members to a temp dir for inspection (or `unzip -p` + temp files).
- Resolve `ZSTD` like other scripts (`tools/zstd/zstd` or `command -v zstd`).
- For each of dxvk / dxmt globs under `Resources/graphics/`:
  - Fail if missing.
  - Fail if `stat` size &lt; min bytes.
  - Fail if first `tar -tv` line starts with `l`.
  - Prefer also failing if no line matches `d3d11.dll` (dxvk) / `winemetal.so` (dxmt) when mins are at production defaults (optional for fixture with zero-filled names — **include those filenames in the test fixtures** as above).
- Check `engine-version.txt` non-empty and at least one `engine-*.tar.zst` (ignore AppleDouble `._*`).
- If `--baseline` set and both zips exist: fail if `size(zip) + 1048576 < size(baseline)` **unless** `--skip-size-vs-baseline` (do **not** add this flag in v1 — keep fail-closed; tests use equal baseline).
- If not `--skip-notarization-checks` and `--app` set: run `spctl -a -vv` and `xcrun stapler validate` (tests always skip).

- [ ] **Step 4: Write SKILL.md**

```markdown
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
```

- [ ] **Step 5: Run test — expect PASS**

Run: `bash /Users/jjc/ogom/tests/test-cyder-release-verify.sh`  
Expected: `PASS test-cyder-release-verify`

- [ ] **Step 6: Commit** (when user approves commits)

```bash
git add .agents/skills/cyder-release-verify tests/test-cyder-release-verify.sh
git commit -m "$(cat <<'EOF'
feat(release): add Cyder.app zip/graphics verify skill

EOF
)"
```

---

### Task 2: Hard-gate `pack-graphics-payloads.sh` (cyder-wine-engine)

**Files:**
- Modify: `cyder-wine-engine/scripts/pack-graphics-payloads.sh`
- Modify: `cyder-wine-engine/tests/test-pack-graphics-payloads.sh`
- If `ogom/scripts/pack-graphics-payloads.sh` is a separate file (not symlink), apply the same gate or replace with a note that agents must pack from the engine repo only.

**Interfaces:**
- Consumes: existing `--engine` / `--force` CLI
- Produces: refuse symlink `lib/dxvk`, `lib/dxvk2`, `lib/dxmt`; after archive write, refuse if size &lt; 1024 bytes (unit-test friendly; production sizes still caught by verify)

- [ ] **Step 1: Extend failing test**

Append to `tests/test-pack-graphics-payloads.sh` before the final PASS:

```bash
# Symlink payload source must be rejected
sym_engine="$tmp/sym-engine"
mkdir -p "$sym_engine/lib" "$tmp/real-dxvk" "$tmp/real-dxvk2" "$tmp/real-dxmt"
printf 'x\n' >"$tmp/real-dxvk/f"
printf 'x\n' >"$tmp/real-dxvk2/f"
printf 'x\n' >"$tmp/real-dxmt/f"
ln -s "$tmp/real-dxvk" "$sym_engine/lib/dxvk"
ln -s "$tmp/real-dxvk2" "$sym_engine/lib/dxvk2"
ln -s "$tmp/real-dxmt" "$sym_engine/lib/dxmt"
set +e
CYDER_ZSTD="$fake_zstd" bash "$ROOT/scripts/pack-graphics-payloads.sh" \
  --engine "$sym_engine" --output-dir "$tmp/sym-out" --force
sym_status=$?
set -e
if [[ "$sym_status" -eq 0 ]]; then
  echo "ASSERT failed: symlink dxvk/dxmt sources must fail" >&2
  exit 1
fi
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash /Users/jjc/cyder-wine-engine/tests/test-pack-graphics-payloads.sh`  
Expected: FAIL (symlink still accepted)

- [ ] **Step 3: Implement gate**

Near the top of `pack-graphics-payloads.sh`, after ENGINE dir checks:

```bash
cyder_graphics_require_realpath_dir() {
  local path="$1" label="$2"
  [[ -d "$path" ]] || { echo "Missing $label: $path" >&2; return 1; }
  if [[ -L "$path" ]]; then
    echo "Refusing symlinked $label source: $path (copy a real tree; symlink packs become stub archives)" >&2
    return 1
  fi
}

cyder_graphics_require_realpath_dir "$ENGINE/lib/dxvk" "DXVK"
cyder_graphics_require_realpath_dir "$ENGINE/lib/dxvk2" "DXVK2"
cyder_graphics_require_realpath_dir "$ENGINE/lib/dxmt" "DXMT"
```

After creating each archive in `pack_payload`, before echoing Created:

```bash
  local min_bytes="${CYDER_GRAPHICS_ARCHIVE_MIN_BYTES:-1024}"
  local sz
  sz="$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive")"
  if (( sz < min_bytes )); then
    echo "Refusing undersized graphics archive $archive ($sz bytes < $min_bytes)" >&2
    return 1
  fi
```

Use `cp -R` only after the symlink check (already on ENGINE paths). Optionally `cp -RHL` is **not** desired for release (would hide the mistake); keep refuse-symlink.

- [ ] **Step 4: Run test — expect PASS**

Run: `bash /Users/jjc/cyder-wine-engine/tests/test-pack-graphics-payloads.sh`  
Expected: `PASS test-pack-graphics-payloads`

- [ ] **Step 5: Commit** (when approved)

```bash
git add scripts/pack-graphics-payloads.sh tests/test-pack-graphics-payloads.sh
git commit -m "$(cat <<'EOF'
fix(pack): reject symlinked graphics payload sources

EOF
)"
```

---

### Task 3: `engine-release-pack` skill (cyder-wine-engine)

**Files:**
- Create: `cyder-wine-engine/.agents/skills/engine-release-pack/SKILL.md`
- Modify: `cyder-wine-engine/.agents/skills/incremental-wine-build/SKILL.md` (add pointer near pack section)
- Modify: `cyder-wine-engine/docs/ai-agent-setup.md` (register skill in table)

**Interfaces:**
- Consumes: Task 2 gates; existing `pack-engine-artifact.sh`, `pack-graphics-payloads.sh`, `sign-wine.sh`
- Produces: agent checklist only (no new binary required)

- [ ] **Step 1: Write SKILL.md**

Include verbatim description from the spec. Body must include:

1. `cd /Users/jjc/cyder-wine-engine`; `export OGOM=…`
2. Refuse `SIGN_IDENTITY=-` for release packs; require Developer ID Application identity from keychain.
3. `WINE_INSTALL` = real `install/wine-cx26-x86_64` or full extracted tree — **never** symlink `lib/dxvk` etc.
4. Commands:

```bash
bash scripts/pack-graphics-payloads.sh --engine "$WINE_INSTALL" --force
SIGN_IDENTITY='Developer ID Application: …' \
CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder0NN' \
  bash scripts/pack-engine-artifact.sh --zst --force
```

5. Post-checks: dual MoltenVK paths in archive; `codesign -dv` on wine + MoltenVK shim/reals shows Developer ID; graphics artifacts in `dist/artifacts/graphics/` each ≫ 1 MiB.
6. Hand off manifest path to ogom `import-engine-release.sh`.

- [ ] **Step 2: Patch incremental-wine-build**

In the pack section of `incremental-wine-build/SKILL.md`, add:

> Formal Developer ID / shipping artifacts: use `.agents/skills/engine-release-pack` instead of ad-hoc `SIGN_IDENTITY=-` packs.

- [ ] **Step 3: Update `docs/ai-agent-setup.md`**

Add `engine-release-pack` to the skills / adapters table.

- [ ] **Step 4: Commit** (when approved)

```bash
git add .agents/skills/engine-release-pack .agents/skills/incremental-wine-build/SKILL.md docs/ai-agent-setup.md
git commit -m "$(cat <<'EOF'
docs(agents): add engine-release-pack skill for shipping artifacts

EOF
)"
```

---

### Task 4: `cyder-release` orchestration + redirect + pipeline docs (ogom)

**Files:**
- Create: `ogom/.agents/skills/cyder-release/SKILL.md`
- Modify: `ogom/.agents/skills/cyder-wine-engine-redirect/SKILL.md`
- Modify: `ogom/docs/release-pipeline.zh-TW.md` (top index linking the three skills)
- Modify: `ogom/docs/superpowers/specs/2026-08-26-cyder-release-skills-design.md` — set status to `approved`

**Interfaces:**
- Consumes: Task 1 verify script; Task 3 pack skill; `scripts/import-engine-release.sh`; `scripts/release-cyder.sh`

- [ ] **Step 1: Write `cyder-release/SKILL.md`**

Description from spec. Body checklist:

1. Read `config/cyder-app-version.txt`; require clean semver for release.
2. Follow `engine-release-pack` in `/Users/jjc/cyder-wine-engine`.
3. `bash scripts/import-engine-release.sh --manifest <path> --apply`
4. `bash scripts/release-cyder.sh --channel release --version <semver>`
5. **Must** run:

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh \
  --app dist/Cyder.app \
  --zip dist/Cyder.app.zip \
  --baseline dist/Cyder-0.13.0.zip   # or next-newest Cyder-*.zip
```

6. On verify failure: stop; if graphics undersized → re-run graphics pack + release; do not publish zip.

- [ ] **Step 2: Update redirect skill**

Add bullets: formal pack → `engine-release-pack`; full shipping flow → `cyder-release`.

- [ ] **Step 3: Update release-pipeline.zh-TW.md**

After the title / intro, add a short「Agent skills」section listing the three paths and that verify is mandatory after release channel.

- [ ] **Step 4: Mark design spec approved**

Change `狀態：draft（待審核）` → `狀態：approved`.

- [ ] **Step 5: Smoke**

```bash
bash /Users/jjc/ogom/tests/test-cyder-release-verify.sh
bash /Users/jjc/cyder-wine-engine/tests/test-pack-graphics-payloads.sh
test -f /Users/jjc/ogom/.agents/skills/cyder-release/SKILL.md
test -f /Users/jjc/cyder-wine-engine/.agents/skills/engine-release-pack/SKILL.md
```

Expected: both tests PASS; files exist.

- [ ] **Step 6: Commit** (when approved; ogom repo)

```bash
git add .agents/skills/cyder-release .agents/skills/cyder-wine-engine-redirect \
  docs/release-pipeline.zh-TW.md docs/superpowers/specs/2026-08-26-cyder-release-skills-design.md
git commit -m "$(cat <<'EOF'
docs(agents): add cyder-release orchestration skill

EOF
)"
```

---

### Task 5 (optional follow-up): wire verify into `release-cyder.sh`

**Files:**
- Modify: `ogom/scripts/release-cyder.sh`
- Modify: `ogom/tests/` — grep-based contract that release script references verify

Only if user wants fail-closed even without loading the skill.

- [ ] **Step 1:** After staple/zip success on `release` channel, invoke verify with `--baseline` auto-detect; `RELEASE_SKIP_VERIFY=1` escape hatch for emergencies.
- [ ] **Step 2:** Test + commit when approved.

Out of scope for the minimum skill landing unless requested.

---

## Spec coverage self-review

| Spec item | Task |
|-----------|------|
| `cyder-release` orchestrator | 4 |
| `engine-release-pack` | 3 |
| `cyder-release-verify` + script | 1 |
| Symlink graphics refusal | 2 |
| Min archive / zip vs baseline / spctl | 1 |
| Update redirect + incremental + docs | 3, 4 |
| No plugin | (global — no task creates one) |
| Optional release-cyder hook | 5 optional |

**Placeholder scan:** none intentional.  
**Type/CLI consistency:** verify flags `--app|--zip|--baseline|--skip-notarization-checks` used in Tasks 1 and 4.
