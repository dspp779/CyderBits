# Retire CX25 OEM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the MapleStory OEM25 app/engine pack and the CX25 Wine build target so Cyder ships only official Cyder.app + CX26, while keeping OEM research docs as history.

**Architecture:** Fail `--cx 25` / `CX_VERSION=25` with one retired message in both repos. Delete OEM packaging scripts and flavor runtime (`CYDER_OEM_FLAVOR`, bootstrap helper). Keep MapleStory.exe WZ-cache detection and CX26 `maplestory-cx26-*.patch`. Do not invent a new cxbottle.conf seed at wineboot.

**Tech Stack:** Bash Wine build scripts, Swift Cyder UI, existing `tests/assert.sh` smoke tests, Conventional Commits in two git repos (`/Users/jjc/cyder-wine-engine`, `/Users/jjc/ogom`).

## Global Constraints

- Retired stderr (exact): `CX25 support was retired; this tree only builds CrossOver 26.`
- `--cx` remains; only `26` is valid. Default `CX_VERSION` stays `26`.
- Do not delete `patches/maplestory-cx26-*.patch` or `patches/oem25-bisect/` data.
- Do not rewrite historical worklogs or old release-note bodies; add the banner sentence only.
- Do not `rm -rf` local `build/cx25`, `install/wine-cx25*`, or OEM bottles.
- Do not add MapleStory.exe-based `RAW_AUDIO_PARSE` injection at bottle create.
- Banner sentence (exact): `CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。`
- Canonical engine scripts live in `/Users/jjc/cyder-wine-engine`. ogom still has copies of `build-wine.sh` / `env-x86_64.sh` / `prepare-build-deps.sh` / `build-graphics-stack.sh` / `build-media-stack.sh` — apply the same CX25 rejection there.
- Spec: `/Users/jjc/ogom/docs/superpowers/specs/2026-08-17-retire-cx25-oem-design.md`

## File map

| File | Responsibility |
|------|----------------|
| `cyder-wine-engine/scripts/env-x86_64.sh` | Reject `CX_VERSION=25`; CX26 prefixes only |
| `cyder-wine-engine/scripts/build-wine.sh` | `--cx` only 26 |
| `cyder-wine-engine/scripts/prepare-build-deps.sh` | No 25.1.1 archive; `--all` = 26 |
| `cyder-wine-engine/scripts/build-graphics-stack.sh` | `--cx` only 26 |
| `cyder-wine-engine/scripts/build-media-stack.sh` | `--cx 25` uses retired message |
| `cyder-wine-engine/scripts/pack-maplestory-oem25-engine.sh` | Delete |
| `cyder-wine-engine/config/engine-release-maplestory-oem25.json` | Delete |
| ogom copies of the same `scripts/*.sh` | Same CX25 rejection |
| ogom OEM app scripts + pins + `test.sh` | Delete |
| `ogom/scripts/cyder-common.sh` / `cyder_settings.swift` / `cyder_app_main.swift` | Remove OEM flavor |
| tests listed per task | Encode the new contract |

---

### Task 1: Engine — failing tests for CX25 retirement

**Files:**
- Modify: `/Users/jjc/cyder-wine-engine/tests/test-build-wine.sh`
- Modify: `/Users/jjc/cyder-wine-engine/tests/test-maplestory-patch-stack.sh`
- Test: those two files

**Interfaces:**
- Consumes: current `scripts/build-wine.sh --cx 25` still succeeds
- Produces: tests that require retired message + missing OEM pack files

- [ ] **Step 1: Replace the CX25 success block in `tests/test-build-wine.sh`**

Delete the block that starts at `output_cx25="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --prepare-only --dry-run` through the `CX25 builds must not migrate or apply CX26-only patches` `fi` / `fi`. Insert:

```bash
retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'

if output_cx25="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --dry-run --without-vulkan 2>&1)"; then
  echo "ASSERT failed: build-wine --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_cx25" "$retired_msg" "build-wine --cx 25 must print the retired message"

if output_prep25="$(bash "$ROOT/scripts/prepare-build-deps.sh" --cx 25 --dry-run 2>&1)"; then
  echo "ASSERT failed: prepare-build-deps --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_prep25" "$retired_msg" "prepare-build-deps --cx 25 must print the retired message"

output_all="$(bash "$ROOT/scripts/prepare-build-deps.sh" --all --dry-run 2>&1 || true)"
if [[ "$output_all" == *"crossover-sources-25.1.1.tar.gz"* || "$output_all" == *"build/cx25"* ]]; then
  echo "ASSERT failed: prepare --all must not mention CX25 archives or build/cx25" >&2
  exit 1
fi
if [[ "$output_all" != *"crossover-sources-26.3.0.tar.gz"* && "$output_all" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: prepare --all should still prepare CX26" >&2
  exit 1
fi

if cx25_env="$(
  export CX_VERSION=25
  unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
  # shellcheck disable=SC1091
  source "$ROOT/scripts/env-x86_64.sh" 2>&1
  echo SHOULD_NOT_REACH
)"; then
  echo "ASSERT failed: CX_VERSION=25 must fail in env-x86_64.sh" >&2
  exit 1
fi
assert_contains "$cx25_env" "$retired_msg" "env-x86_64.sh must print the retired message for CX25"

if graphics25="$(bash "$ROOT/scripts/build-graphics-stack.sh" --cx 25 --dry-run 2>&1)"; then
  echo "ASSERT failed: build-graphics-stack --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$graphics25" "$retired_msg" "build-graphics-stack --cx 25 must print the retired message"

if media25="$(bash "$ROOT/scripts/build-media-stack.sh" --cx 25 2>&1)"; then
  echo "ASSERT failed: build-media-stack --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$media25" "$retired_msg" "build-media-stack --cx 25 must print the retired message"

[[ ! -e "$ROOT/scripts/pack-maplestory-oem25-engine.sh" ]] || {
  echo "ASSERT failed: pack-maplestory-oem25-engine.sh must be removed" >&2
  exit 1
}
[[ ! -e "$ROOT/config/engine-release-maplestory-oem25.json" ]] || {
  echo "ASSERT failed: engine-release-maplestory-oem25.json must be removed" >&2
  exit 1
}
```

Keep every existing CX26 assertion above this block.

- [ ] **Step 2: Replace the MapleStory CX25 assertion in `tests/test-maplestory-patch-stack.sh`**

Replace the `if cx25_output="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --maplestory ...` block with:

```bash
if cx25_output="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --maplestory --dry-run --without-vulkan 2>&1)"; then
  echo "ASSERT failed: --cx 25 must be rejected" >&2
  exit 1
else
  assert_contains "$cx25_output" "CX25 support was retired; this tree only builds CrossOver 26." \
    "CX25 source builds must be retired"
fi
```

- [ ] **Step 3: Run tests — expect FAIL**

```bash
cd /Users/jjc/cyder-wine-engine
bash tests/test-build-wine.sh
bash tests/test-maplestory-patch-stack.sh
```

Expected: FAIL because `--cx 25` still prepares CX25 / OEM pack files still exist / MapleStory still prints `supports only --cx 26`.

- [ ] **Step 4: Do not commit failing tests alone**

Continue to Task 2 in the same engine working tree.

---

### Task 2: Engine — reject CX25 and delete OEM pack

**Files:**
- Modify: `/Users/jjc/cyder-wine-engine/scripts/env-x86_64.sh`
- Modify: `/Users/jjc/cyder-wine-engine/scripts/build-wine.sh`
- Modify: `/Users/jjc/cyder-wine-engine/scripts/prepare-build-deps.sh`
- Modify: `/Users/jjc/cyder-wine-engine/scripts/build-graphics-stack.sh`
- Modify: `/Users/jjc/cyder-wine-engine/scripts/build-media-stack.sh`
- Delete: `/Users/jjc/cyder-wine-engine/scripts/pack-maplestory-oem25-engine.sh`
- Delete: `/Users/jjc/cyder-wine-engine/config/engine-release-maplestory-oem25.json`
- Test: `tests/test-build-wine.sh`, `tests/test-maplestory-patch-stack.sh`

**Interfaces:**
- Consumes: Task 1 failing assertions; retired message string
- Produces: `--cx 25` / `CX_VERSION=25` exit 1 with that message; no OEM pack script

- [ ] **Step 1: `env-x86_64.sh` — CX26 only**

Replace the `case "$CX_VERSION"` block with:

```bash
case "$CX_VERSION" in
  25)
    echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
    exit 1
    ;;
  26)
    export CYDER_ENGINE_CX_PREFIX="${CYDER_ENGINE_CX_PREFIX:-CX26}"
    export WINE_SRC="${WINE_SRC:-$BUILD_DIR/cx26/sources/wine}"
    export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-cx26-x86_64}"
    ;;
  *)
    echo "Unknown CX_VERSION: $CX_VERSION (expected 26)" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: `build-wine.sh` — parse `--cx` as 26 only**

In the `--help` text, change `--cx 25|26` to `--cx 26`.

Replace the `case "$CX_VERSION"` after argument parsing with:

```bash
case "$CX_VERSION" in
  25)
    echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
    exit 1
    ;;
  26) ;;
  *)
    echo "Unknown --cx value: $CX_VERSION (expected 26)" >&2
    exit 1
    ;;
esac
```

Delete these two now-dead checks:

```bash
if [[ "$MAPLESTORY" -eq 1 && "$CX_VERSION" != "26" ]]; then
  echo "--maplestory currently supports only --cx 26" >&2
  exit 1
fi

if [[ "$VULKAN_SONAME_FALLBACK" -eq 1 && "$CX_VERSION" != "26" ]]; then
  echo "--vulkan-soname-fallback currently supports only --cx 26" >&2
  exit 1
fi
```

Keep the later `if [[ "$CX_VERSION" == "26" ]]; then` patch-apply branch; it is still correct.

- [ ] **Step 3: `prepare-build-deps.sh`**

Help: `--cx 26` and `--all` = CX26 only.

Replace `cx_archive_for`:

```bash
cx_archive_for() {
  case "$1" in
    25)
      echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
      return 1
      ;;
    26) printf '%s\n' "$ARCHIVES_DIR/crossover-sources-26.3.0.tar.gz" ;;
    *)
      echo "Unknown CX version: $1 (expected 26)" >&2
      return 1
      ;;
  esac
}
```

`--all)` must be `CX_VERSIONS+=(26)` not `+(25 26)`.

Default when empty: `CX_VERSIONS=(26)` not `(25 26)`.

Loop:

```bash
for ver in "${CX_VERSIONS[@]}"; do
  case "$ver" in
    25)
      echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
      exit 1
      ;;
    26) ensure_cx_sources "$ver" ;;
    *)
      echo "Unknown CX version: $ver (expected 26)" >&2
      exit 1
      ;;
  esac
done
```

- [ ] **Step 4: `build-graphics-stack.sh`**

Help: `--cx 26`. Same `case "$CX_VERSION"` as `build-wine.sh` (retired message for 25, expected 26 otherwise). Keep `source env-x86_64.sh` after the case.

- [ ] **Step 5: `build-media-stack.sh`**

Replace the non-26 guard with:

```bash
if [[ "$CX_VERSION" == 25 ]]; then
  echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
  exit 1
fi
[[ "$CX_VERSION" == 26 ]] || {
  echo "The minimal media build is currently validated only with CX26." >&2
  exit 1
}
```

- [ ] **Step 6: Delete OEM pack files**

```bash
cd /Users/jjc/cyder-wine-engine
git rm scripts/pack-maplestory-oem25-engine.sh config/engine-release-maplestory-oem25.json
```

- [ ] **Step 7: Run tests — expect PASS**

```bash
cd /Users/jjc/cyder-wine-engine
bash tests/test-build-wine.sh
bash tests/test-maplestory-patch-stack.sh
```

Expected: `PASS test-build-wine` and MapleStory patch stack PASS (or SKIP only if CX26.3.0 tarball is absent — that SKIP already existed).

- [ ] **Step 8: Commit (engine repo)**

```bash
cd /Users/jjc/cyder-wine-engine
git add scripts/env-x86_64.sh scripts/build-wine.sh scripts/prepare-build-deps.sh \
  scripts/build-graphics-stack.sh scripts/build-media-stack.sh \
  tests/test-build-wine.sh tests/test-maplestory-patch-stack.sh
git commit -m "$(cat <<'EOF'
chore: retire CX25 wine builds and OEM25 engine pack

CX25 existed only for MapleStory OEM experiments; the tree now builds CrossOver 26 only.

EOF
)"
```

---

### Task 3: Engine — live docs

**Files:**
- Modify: `/Users/jjc/cyder-wine-engine/AGENTS.md`
- Modify: `/Users/jjc/cyder-wine-engine/.cursor/rules/incremental-build-and-patches.mdc`
- Modify: `/Users/jjc/cyder-wine-engine/docs/incremental-build-and-patches.md`
- Modify: `/Users/jjc/cyder-wine-engine/patches/README.md`
- Modify: `/Users/jjc/cyder-wine-engine/docs/maplestory-cx26-worklog.zh-TW.md` (banner only)

**Interfaces:**
- Consumes: engine is CX26-only
- Produces: live instructions no longer describe building CX25

- [ ] **Step 1: `AGENTS.md`**

Replace `- Frame-walk and wineserver patches are **CX26-only**.` with:

```markdown
- This tree builds **CrossOver 26 only**. `--cx 25` is retired.
```

- [ ] **Step 2: `.cursor/rules/incremental-build-and-patches.mdc`**

Replace `CX26-only wineserver/frame-walk patches` with `CX26-only engine (CX25 retired), wineserver/frame-walk patches, pack gates`.

- [ ] **Step 3: `docs/incremental-build-and-patches.md`**

Replace hard rule 6:

```markdown
6. **This tree builds CX26 only.** `--cx 25` is retired. Frame-walk and
   wineserver patches apply to the CX26 tree (`tests/test-build-wine.sh`
   asserts `--cx 25` fails with the retired message).
```

- [ ] **Step 4: `patches/README.md`**

Replace:

```markdown
The frame-walk and wineserver patches are intentionally CX26-only. CX25 uses a
Wine 10 base and must not receive them without a separate source and ABI review.
```

with:

```markdown
The frame-walk and wineserver patches apply to this CX26-only tree. CX25
source builds are retired.
```

Leave the sentence that D3DMetal matches the historical CX25 OEM runtime — that is research context, not a build instruction.

- [ ] **Step 5: Worklog banner**

Insert immediately after the title in `docs/maplestory-cx26-worklog.zh-TW.md`:

```markdown
> CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。
```

Do not edit the dated experiment entries.

- [ ] **Step 6: Commit (engine repo)**

```bash
cd /Users/jjc/cyder-wine-engine
git add AGENTS.md .cursor/rules/incremental-build-and-patches.mdc \
  docs/incremental-build-and-patches.md patches/README.md \
  docs/maplestory-cx26-worklog.zh-TW.md
git commit -m "$(cat <<'EOF'
docs: record that the engine tree builds CX26 only

EOF
)"
```

---

### Task 4: ogom — failing tests for CX25 retirement

**Files:**
- Modify: `/Users/jjc/ogom/tests/test-build-wine.sh`
- Modify: `/Users/jjc/ogom/tests/test-env-x86_64.sh`
- Modify: `/Users/jjc/ogom/tests/test-prepare-build-deps.sh`
- Test: those three files

**Interfaces:**
- Consumes: ogom copies of build scripts still accept CX25
- Produces: same retired-message contract as engine Task 1 (without OEM pack file checks)

- [ ] **Step 1: `tests/test-build-wine.sh`**

Replace the CX25 prepare/success block (the `output_cx25=... --cx 25 --prepare-only` through `CX25 builds must not migrate...`) with:

```bash
retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'
if output_cx25="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --dry-run --without-vulkan 2>&1)"; then
  echo "ASSERT failed: build-wine --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_cx25" "$retired_msg" "build-wine --cx 25 must print the retired message"
```

Keep all CX26 assertions.

- [ ] **Step 2: `tests/test-env-x86_64.sh`**

Delete the block:

```bash
export CX_VERSION=25
unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
source "$ROOT/scripts/env-x86_64.sh"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-cx25-x86_64" ...
```

Insert after the CX26 assertions (before the `/opt/homebrew` leak test):

```bash
retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'
if cx25_env="$(
  export CX_VERSION=25
  unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
  # shellcheck disable=SC1091
  source "$ROOT/scripts/env-x86_64.sh" 2>&1
  echo SHOULD_NOT_REACH
)"; then
  echo "ASSERT failed: CX_VERSION=25 must fail in env-x86_64.sh" >&2
  exit 1
fi
assert_contains "$cx25_env" "$retired_msg" "env-x86_64.sh must print the retired message for CX25"
```

Keep the `/opt/homebrew` leak test. That test sources env again with default/26 — set `export CX_VERSION=26` before it if the failed CX25 attempt could leak (it cannot; it ran in a subshell). Still set `unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX` as today.

- [ ] **Step 3: `tests/test-prepare-build-deps.sh`**

Replace the `--all` CX25 assertion with:

```bash
retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'
if output_prep25="$(bash "$ROOT/scripts/prepare-build-deps.sh" --cx 25 --dry-run 2>&1)"; then
  echo "ASSERT failed: prepare-build-deps --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_prep25" "$retired_msg" "prepare --cx 25 must print the retired message"

output_all="$(bash "$ROOT/scripts/prepare-build-deps.sh" --all --dry-run 2>&1 || true)"
if [[ "$output_all" == *"crossover-sources-25.1.1.tar.gz"* || "$output_all" == *"build/cx25"* ]]; then
  echo "ASSERT failed: prepare --all must not mention CX25" >&2
  exit 1
fi
if [[ "$output_all" != *"crossover-sources-26.3.0.tar.gz"* && "$output_all" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: prepare --all should still prepare CX26" >&2
  exit 1
fi
```

Keep the `--cx 26` dry-run assertions at the top of the file.

- [ ] **Step 4: Run — expect FAIL**

```bash
cd /Users/jjc/ogom
bash tests/test-build-wine.sh
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
```

Expected: FAIL on retired-message assertions.

---

### Task 5: ogom — reject CX25 in leftover engine scripts

**Files:**
- Modify: `/Users/jjc/ogom/scripts/env-x86_64.sh`
- Modify: `/Users/jjc/ogom/scripts/build-wine.sh`
- Modify: `/Users/jjc/ogom/scripts/prepare-build-deps.sh`
- Modify: `/Users/jjc/ogom/scripts/build-graphics-stack.sh`
- Modify: `/Users/jjc/ogom/scripts/build-media-stack.sh`

**Interfaces:**
- Consumes: same retired message and case structure as Task 2
- Produces: ogom copies match the CX25 rejection contract

- [ ] **Step 1: Apply the same script edits as Task 2 Steps 1–5**

ogom `build-wine.sh` is an older copy: it has `--cx 25|26` and `case 25 | 26` but may lack `--maplestory`. Still:

- help `--cx 26`
- `25)` prints the retired message and `exit 1`
- `26)` ok
- `*)` `expected 26`
- `env-x86_64.sh` / `prepare-build-deps.sh` / `build-graphics-stack.sh` / `build-media-stack.sh` same as engine Task 2

Do not copy engine-only MapleStory patch apply lists into ogom `build-wine.sh`.

- [ ] **Step 2: Run — expect PASS**

```bash
cd /Users/jjc/ogom
bash tests/test-build-wine.sh
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
```

Expected: all three PASS.

- [ ] **Step 3: Commit (ogom)**

```bash
cd /Users/jjc/ogom
git add scripts/env-x86_64.sh scripts/build-wine.sh scripts/prepare-build-deps.sh \
  scripts/build-graphics-stack.sh scripts/build-media-stack.sh \
  tests/test-build-wine.sh tests/test-env-x86_64.sh tests/test-prepare-build-deps.sh
git commit -m "$(cat <<'EOF'
chore: retire CX25 wine build target

Match the engine repo: CrossOver 25 exists only as historical MapleStory OEM research.

EOF
)"
```

---

### Task 6: ogom — failing tests for OEM product removal

**Files:**
- Modify: `/Users/jjc/ogom/tests/test-cyder-app-payload.sh`
- Modify: `/Users/jjc/ogom/tests/test-cyder-crossover-bottle-conf.sh`
- Modify: `/Users/jjc/ogom/tests/test-cyder-settings-swift.sh`
- Modify: `/Users/jjc/ogom/tests/fixtures/cyder_settings_harness.swift`
- Modify: `/Users/jjc/ogom/tests/test-cyder-dxvk-multi-engine.sh`

**Interfaces:**
- Consumes: OEM scripts still present; `cyder_is_maplestory_oem` still injects RAW_AUDIO_PARSE
- Produces: tests that require OEM files gone and no OEM flavor API

- [ ] **Step 1: `tests/test-cyder-app-payload.sh`**

Delete the block from `oem_build_script="$(cat "$ROOT/scripts/create-cyder-maplestory-oem-app.sh")"` through the `MacOS/Cyder |` whitelist check.

Insert:

```bash
[[ ! -e "$ROOT/scripts/create-cyder-maplestory-oem-app.sh" ]] || {
  echo "ASSERT failed: MapleStory OEM app packer must be removed" >&2
  exit 1
}
[[ ! -e "$ROOT/scripts/cyder_maplestory_oem_main.sh" ]] || {
  echo "ASSERT failed: MapleStory OEM launcher must be removed" >&2
  exit 1
}
[[ ! -e "$ROOT/scripts/cyder_oem_bootstrap_main.sh" ]] || {
  echo "ASSERT failed: OEM bootstrap helper must be removed" >&2
  exit 1
}
```

- [ ] **Step 2: `tests/test-cyder-crossover-bottle-conf.sh`**

Delete the whole OEM seed block (`# MapleStory OEM bottles receive...` through the `LC_CTYPE` assert).

Keep generic seed must **not** contain `RAW_AUDIO_PARSE`.

Replace the override subshell names:

```bash
  export CYDER_ENGINE_NAME=custom-engine
  export CYDER_BOTTLE_NAME=custom-bottle
  export CYDER_SUPPORT="$TMP/cyder-support"
  unset CYDER_PREFIX CYDER_SHARED_PREFIX CYDER_OEM_FLAVOR
  # shellcheck source=../scripts/cyder-common.sh
  source "$ROOT/scripts/cyder-common.sh"
  cyder_init_paths "$ROOT/scripts"
  assert_eq "$CYDER_ENGINE_NAME" "custom-engine" "engine name override"
  assert_eq "$CYDER_PREFIX" \
    "$TMP/cyder-support/bottles/custom-bottle" \
    "prefix path uses CYDER_BOTTLE_NAME"
  assert_eq "$CYDER_SHARED_PREFIX" \
    "$TMP/cyder-support/bottles/custom-bottle" \
    "shared prefix remains a compatibility alias"
```

Also delete `unset CYDER_OEM_FLAVOR` at the top if nothing else needs it; harmless to leave one `unset` until Task 7 removes the variable from `cyder-common.sh`.

Add after sourcing `cyder-common.sh` near the top (after the generic seed test):

```bash
if type cyder_is_maplestory_oem >/dev/null 2>&1; then
  echo "ASSERT failed: cyder_is_maplestory_oem must be removed" >&2
  exit 1
fi
```

- [ ] **Step 3: Settings harness**

In `tests/fixtures/cyder_settings_harness.swift`, delete:

```swift
        setenv("CYDER_OEM_FLAVOR", "maplestory", 1)
        defer { unsetenv("CYDER_OEM_FLAVOR") }
        precondition(CyderProduct.isMapleStoryOEM)
```

Keep `precondition(CyderProduct.defaultGraphicsBackend == .default)` and the following graphics preconditions.

In `tests/test-cyder-settings-swift.sh`, delete the comment line `- OEM (CYDER_OEM_FLAVOR=maplestory): ...` and `unset CYDER_OEM_FLAVOR` (keep other unsets).

- [ ] **Step 4: `tests/test-cyder-dxvk-multi-engine.sh`**

Replace the hardcoded OEM default:

```bash
E1="${CYDER_DXVK_ENGINE1:-$ROOT/install/wine-cx26-x86_64}"
E2="${CYDER_DXVK_ENGINE2:-$ROOT/install/wine-cx26-x86_64}"
```

- [ ] **Step 5: Run — expect FAIL**

```bash
cd /Users/jjc/ogom
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-crossover-bottle-conf.sh
```

Expected: FAIL because OEM scripts still exist / `cyder_is_maplestory_oem` still defined.

`bash tests/test-cyder-settings-swift.sh` may still PASS until `isMapleStoryOEM` is deleted (harness no longer calls it). That is OK.

`bash tests/test-cyder-dxvk-multi-engine.sh` should still PASS after Step 4 if CX26 install exists or dry-run does not require the tree.

---

### Task 7: ogom — delete OEM product and flavor runtime

**Files:**
- Delete: `/Users/jjc/ogom/scripts/create-cyder-maplestory-oem-app.sh`
- Delete: `/Users/jjc/ogom/scripts/cyder_maplestory_oem_main.sh`
- Delete: `/Users/jjc/ogom/scripts/cyder_oem_bootstrap_main.sh`
- Delete: `/Users/jjc/ogom/config/cyder-oem-engine-archive.txt`
- Delete: `/Users/jjc/ogom/config/cyder-oem-engine-version.txt`
- Delete: `/Users/jjc/ogom/patches/maplestory-oem25-source-distversion.patch`
- Delete: `/Users/jjc/ogom/test.sh`
- Modify: `/Users/jjc/ogom/scripts/cyder-common.sh`
- Modify: `/Users/jjc/ogom/scripts/cyder_settings.swift`
- Modify: `/Users/jjc/ogom/scripts/cyder_app_main.swift`

**Interfaces:**
- Consumes: Task 6 failing assertions
- Produces: no OEM packers; no `cyder_is_maplestory_oem`; WZ cache still via `cyder_is_maplestory_executable`

- [ ] **Step 1: Delete OEM files**

```bash
cd /Users/jjc/ogom
git rm scripts/create-cyder-maplestory-oem-app.sh \
  scripts/cyder_maplestory_oem_main.sh \
  scripts/cyder_oem_bootstrap_main.sh \
  config/cyder-oem-engine-archive.txt \
  config/cyder-oem-engine-version.txt \
  patches/maplestory-oem25-source-distversion.patch \
  test.sh
```

- [ ] **Step 2: `cyder-common.sh` — seed without OEM extras**

In `cyder_seed_crossover_bottle_conf`, delete from `local is_maplestory=0` through the locale `for locale_key` loop, inclusive. Leave WineArch / Template injection and the `Seeded CrossOver bottle metadata` echo.

Delete the entire function:

```bash
cyder_is_maplestory_oem() {
  [[ "${CYDER_OEM_FLAVOR:-}" == maplestory ||
     "${CYDER_ENGINE_NAME:-}" == maplestory*oem* ||
     "${CYDER_BOTTLE_NAME:-}" == maplestory* ]]
}
```

Change WZ cache to executable-only:

```bash
cyder_apply_maplestory_wz_cache() {
  local exe="$1"
  if cyder_is_maplestory_executable "$exe"; then
    export CYDER_MAPLESTORY_FILE_CACHE="${CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE:-1}"
  else
    export CYDER_MAPLESTORY_FILE_CACHE=0
  fi
}
```

In `cyder_apply_graphics_runtime_preferences`, change:

```bash
  if [[ -n "$fps" ]] \
     && [[ "$backend" == dxvk ]] \
     && { [[ "$preference" == dxvk ]] || cyder_is_maplestory_oem; }; then
    export DXVK_FRAME_RATE="$fps"
  fi
```

to:

```bash
  if [[ -n "$fps" ]] \
     && [[ "$backend" == dxvk ]] \
     && [[ "$preference" == dxvk ]]; then
    export DXVK_FRAME_RATE="$fps"
  fi
```

Update comments that say “MapleStory OEM engines” on `cyder_crossover_bottle_data_conf` to “CrossOver engines” if they claim OEM-only; keep the Perl-frontend `cxbottle.conf` behavior.

- [ ] **Step 3: `cyder_settings.swift`**

Delete from `enum CyderProduct`:

```swift
    /// MapleStory OEM ships a dedicated App wrapper that exports this flavor.
    static var isMapleStoryOEM: Bool {
        ProcessInfo.processInfo.environment["CYDER_OEM_FLAVOR"] == "maplestory"
    }

```

Keep `defaultGraphicsBackend`. If the official/OEM comment on that property mentions OEM, change it to “Official builds leave the global default unchanged.”

- [ ] **Step 4: `cyder_app_main.swift`**

Delete the OEM helper branch, leaving the normal bootstrap:

```swift
        var bootstrapNeeded = state.needsEngine
            || state.needsBootstrap
            || environmentState(context: context).needsBootstrap
            || !templatesReady && !state.needsEngine
        var bootstrapHealthChecked = false
        if bootstrapNeeded {
            CyderDiagnostics.shared.enter(.bootstrap)
            showSetup("正在準備遊戲環境…")
```

Do not leave a reference to `CYDER_OEM_BOOTSTRAP_HELPER`.

- [ ] **Step 5: Run — expect PASS**

```bash
cd /Users/jjc/ogom
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-crossover-bottle-conf.sh
bash tests/test-cyder-settings-swift.sh
bash tests/test-cyder-dxvk-multi-engine.sh
```

Expected: all PASS.

- [ ] **Step 6: Commit (ogom)**

```bash
cd /Users/jjc/ogom
git add -A scripts/cyder-common.sh scripts/cyder_settings.swift scripts/cyder_app_main.swift \
  tests/test-cyder-app-payload.sh tests/test-cyder-crossover-bottle-conf.sh \
  tests/test-cyder-settings-swift.sh tests/fixtures/cyder_settings_harness.swift \
  tests/test-cyder-dxvk-multi-engine.sh
git commit -m "$(cat <<'EOF'
chore: remove MapleStory OEM25 app flavor

CX26 official Cyder now runs MapleStory; drop the dedicated OEM wrapper and flavor env.

EOF
)"
```

`git add -A` here is only to pick up the `git rm` deletions from Step 1 plus the listed modifications. Do not add unrelated untracked files (for example `logo/*.png`).

---

### Task 8: ogom — live docs and issue template

**Files:**
- Modify: `/Users/jjc/ogom/README.md`, `/Users/jjc/ogom/README.zh-TW.md`
- Modify: `/Users/jjc/ogom/docs/wine-configure-options.md`
- Modify: `/Users/jjc/ogom/docs/release-pipeline.zh-TW.md`
- Modify: `/Users/jjc/ogom/docs/release-signing.zh-TW.md`
- Modify: `/Users/jjc/ogom/docs/games/maplestory/README.md`
- Modify: `/Users/jjc/ogom/docs/games/README.md`
- Modify: `/Users/jjc/ogom/docs/project-development-dashboard.zh-TW.md`
- Modify: `/Users/jjc/ogom/.github/ISSUE_TEMPLATE/cyder-problem-report.yml`
- Modify: `/Users/jjc/ogom/patches/README.md`
- Modify: `/Users/jjc/ogom/docs/maplestory-classic-cx26-frame-walk-debug.md` (live “CX25 排除測試” pointers only)
- Add (already written): `/Users/jjc/ogom/docs/superpowers/specs/2026-08-17-retire-cx25-oem-design.md`
- Add: `/Users/jjc/ogom/docs/superpowers/plans/2026-08-17-retire-cx25-oem.md` (this file)

**Interfaces:**
- Consumes: OEM scripts gone; `--cx 25` retired
- Produces: no live pack/build commands for OEM or CX25

- [ ] **Step 1: READMEs**

`README.md` Wine sources: extract only `build/cx26/`. Commands:

```bash
bash scripts/build-wine.sh --cx 26
bash scripts/sign-wine.sh
```

Delete the `--cx 25` line. Tree: delete `wine-cx25-x86_64/`. Same for `README.zh-TW.md` (delete `A/B 對照 CX25`).

- [ ] **Step 2: `docs/wine-configure-options.md`**

Change checklist item 1 to: `CX 版本：--cx 26（crossover-sources-26.3.0.tar.gz）。CX25 已退役。`

- [ ] **Step 3: Release docs**

Replace `docs/release-pipeline.zh-TW.md` section `### MapleStory OEM25 測試引擎` and `## OEM flavor` with:

```markdown
### MapleStory OEM25（已退役）

CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

研究紀錄見 [OEM CX25 修補總覽](games/maplestory/oem-cx25-maplestory-patches.md)。
```

In `docs/release-signing.zh-TW.md`, replace the OEM25 archive paragraph (the `MapleStory OEM25 使用獨立的 engine archive` block) and the entire `## MapleStory OEM flavor 公證` section with the same banner plus a pointer to official `release-cyder.sh --channel release`. Also change the checklist line that says OEM `ntdll.so` hash if present: keep host minOS; drop OEM-specific ntdll wording.

In `docs/release-pipeline.zh-TW.md` checklist, change `- [ ] Engine：host Mach-O minos ≤ 10.15；OEM repack 的原始 ntdll.so hash 未變更` to `- [ ] Engine：host Mach-O minos ≤ 10.15`.

- [ ] **Step 4: MapleStory index and dashboard**

`docs/games/maplestory/README.md`: change **目前調查主線** to CX26 official Cyder. Replace the `bash scripts/create-cyder-oem-test-app.sh` / `create-cyder-oem-engine-test-app.sh` / `create-cyder-maplestory-oem-app.sh` how-to blocks with the banner sentence and keep research links.

`docs/games/README.md` table cell: `正式 Cyder + CX26 可跑新楓之谷；OEM-25 僅歷史紀錄`.

`docs/project-development-dashboard.zh-TW.md` section 3: mark OEM 特別版整合 ⚫ 已退役; CX26 完整可玩 row should reflect that CX26 now runs 新楓之谷 (do not invent a new P0). Delete the live `create-cyder-maplestory-oem-app.sh` status.

- [ ] **Step 5: Issue template**

`description:` → `回報在 macOS 上使用 Cyder 執行遊戲時遇到的問題。`

Markdown: only **Cyder** (delete `或 Cyder-maplestory-oem`).

Dropdown `cyder-edition`: options `Cyder` and `不確定` only.

- [ ] **Step 6: `patches/README.md` (ogom)**

Under MapleStory OEM / CX26 reference patches, add the banner. Change the `maplestory-oem25-source-distversion.patch` row to “deleted; see git history / `docs/upstream-prs/maplestory-oem25-distversion.md`”. Keep `oem25-bisect/` as historical evidence, with “不再建 OEM／CX25 引擎”.

- [ ] **Step 7: Frame-walk debug live pointers**

In `docs/maplestory-classic-cx26-frame-walk-debug.md`, replace “CX25 dry-run 不包含 frame-walk patch” / “CX26 套用／CX25 排除測試” with: `tests/test-build-wine.sh` now asserts `--cx 25` is retired. Leave the experimental narrative in §套用到 CX25 as history; prefix that heading with the banner sentence.

- [ ] **Step 8: Commit (ogom)**

```bash
cd /Users/jjc/ogom
git add README.md README.zh-TW.md docs/wine-configure-options.md \
  docs/release-pipeline.zh-TW.md docs/release-signing.zh-TW.md \
  docs/games/maplestory/README.md docs/games/README.md \
  docs/project-development-dashboard.zh-TW.md \
  .github/ISSUE_TEMPLATE/cyder-problem-report.yml patches/README.md \
  docs/maplestory-classic-cx26-frame-walk-debug.md \
  docs/superpowers/specs/2026-08-17-retire-cx25-oem-design.md \
  docs/superpowers/plans/2026-08-17-retire-cx25-oem.md
git commit -m "$(cat <<'EOF'
docs: retire CX25 OEM build and packaging instructions

EOF
)"
```

---

### Task 9: Historical banners only

**Files:**
- Modify: `/Users/jjc/ogom/docs/games/maplestory/oem-cx25-maplestory-patches.md`
- Modify: `/Users/jjc/ogom/docs/games/maplestory/oem-engine-differences.md`
- Modify: `/Users/jjc/ogom/docs/games/maplestory/oem25-tw-success-baseline.md`
- Modify: `/Users/jjc/ogom/docs/maplestory-oem25-dxvk-d3dmetal-test.md`
- Modify: `/Users/jjc/ogom/docs/upstream-prs/maplestory-oem25-distversion.md`
- Modify: `/Users/jjc/ogom/patches/oem25-bisect/README.md`
- Modify: `/Users/jjc/ogom/docs/releases/v0.7.0.md`, `v0.7.0.en.md`, `v0.8.0.md`, `v0.8.0.en.md`

**Interfaces:**
- Consumes: banner sentence from Global Constraints
- Produces: research files unchanged except a one-line banner after the title

- [ ] **Step 1: Insert the banner**

After each file’s `#` title (or after the existing `更新：` line if that reads more naturally — prefer immediately under the H1):

```markdown
> CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。
```

Do not edit `oem25-bisect/group-*` data files.

In `patches/oem25-bisect/README.md`, after the banner, add one sentence: do not run `prepare-maplestory-oem25-reverse-group.sh` / `run-maplestory-cx25-source-ab.sh`; those trees are not built anymore.

In `docs/upstream-prs/maplestory-oem25-distversion.md`, after the banner, change “Patch: `patches/maplestory-oem25-source-distversion.patch`” to “Patch removed from the tree; see git history.”

Do not rewrite v0.7.0 / v0.8.0 feature lists.

- [ ] **Step 2: Commit (ogom)**

```bash
cd /Users/jjc/ogom
git add docs/games/maplestory/oem-cx25-maplestory-patches.md \
  docs/games/maplestory/oem-engine-differences.md \
  docs/games/maplestory/oem25-tw-success-baseline.md \
  docs/maplestory-oem25-dxvk-d3dmetal-test.md \
  docs/upstream-prs/maplestory-oem25-distversion.md \
  patches/oem25-bisect/README.md \
  docs/releases/v0.7.0.md docs/releases/v0.7.0.en.md \
  docs/releases/v0.8.0.md docs/releases/v0.8.0.en.md
git commit -m "$(cat <<'EOF'
docs: mark CX25 OEM research notes as historical

EOF
)"
```

---

### Task 10: Final verification

**Files:** none (read-only)

- [ ] **Step 1: Engine tests**

```bash
cd /Users/jjc/cyder-wine-engine
bash tests/run.sh
```

Expected: every `test-*.sh` in `tests/run.sh` PASSes. Known SKIP only if `crossover-sources-26.3.0.tar.gz` is missing for the MapleStory patch apply loop.

- [ ] **Step 2: ogom tests from the spec**

```bash
cd /Users/jjc/ogom
bash tests/test-build-wine.sh
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-crossover-bottle-conf.sh
bash tests/test-cyder-settings-swift.sh
bash tests/test-cyder-dxvk-multi-engine.sh
```

Expected: all PASS.

- [ ] **Step 3: Grep gates (must be empty of live packers)**

```bash
cd /Users/jjc/ogom
test ! -e scripts/create-cyder-maplestory-oem-app.sh
test ! -e scripts/pack-maplestory-oem25-engine.sh
cd /Users/jjc/cyder-wine-engine
test ! -e scripts/pack-maplestory-oem25-engine.sh
```

```bash
cd /Users/jjc/cyder-wine-engine
bash scripts/build-wine.sh --cx 25 --dry-run; echo exit:$?
```

Expected: non-zero exit and the retired message on stderr.

- [ ] **Step 4: Do not delete local `build/cx25` or OEM bottles**

If the user wants disk back, list the paths from the spec §6; do not delete them in this plan.
