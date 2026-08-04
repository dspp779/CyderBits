# Dual Font Replacements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `fontPreset` with two independent Wine font-replacement targets (`fontMingLiuTarget` / `fontSongtiTarget`), each choosable as 細明體 / 宋體 / 微軟正黑體.

**Architecture:** Settings schema 8 stores two target IDs. Apply scripts keep `HKCU\Software\Wine\Fonts\Replacements` active and add/delete per-family values (no whole-key `(disabled)` rename). UI exposes two popups; env vars `CYDER_FONT_MINGLIU_TARGET` / `CYDER_FONT_SONGTI_TARGET` drive shell apply paths. Old `fontPreset` is migration-only.

**Tech Stack:** Swift AppKit settings, bash Wine `reg` + `sed` fast user.reg editor, existing bash test harness under `tests/`.

**Spec:** `docs/superpowers/specs/2026-08-04-dual-font-replacements-design.md`

## Global Constraints

- Target IDs only: `mingliu` | `songti` | `jhenghei`.
- Faces: `MingLiU`, `Songti TC`, `Microsoft JhengHei` (no PingFang auto-fallback).
- MingLiU family + `mingliu` → delete those replacement values (do not write identity maps).
- Songti family + `songti` → still write `SimSun`/… → `Songti TC`.
- `MS Shell Dlg`, `MS Shell Dlg 2`, `Microsoft Sans Serif` belong to the MingLiU family.
- Do not redistribute fonts; do not change font-smoothing / Retina / DPI semantics.
- Prefer Conventional Commits when committing; do not push; skip commits if the user has not asked to commit in the current session (user rule overrides plan commit steps — stage work and stop at “ready to commit” instead).

## File map

| File | Responsibility |
|------|----------------|
| `scripts/cyder_settings.swift` | Schema 8 fields, migration, sanitize, env export |
| `scripts/cyder-common.sh` | Shell defaults, plutil extract, profile JSON keys |
| `scripts/cyder-apply-settings.sh` | Wine `reg` add/delete for both families; drop `(disabled)` key |
| `scripts/cyder-edit-user-reg.sh` | Fast sed path for per-key replacements |
| `scripts/cyder-songti-replacements.reg` | Bootstrap default: both families → Songti TC |
| `scripts/cyder-apply-golden-settings.sh` | Golden baseline registry + state |
| `scripts/cyder_settings_ui.swift` | Two global popups |
| `scripts/cyder_game_library_ui.swift` | Two per-game popups |
| `docs/workarounds/font-default.md` | User-facing docs |
| `tests/test-cyder-settings.sh` | Apply-settings behavior |
| `tests/test-cyder-fast-user-reg.sh` | Fast sed behavior |
| `tests/test-cyder-force-settings-ui.sh` | UI string contracts |
| `tests/test-cyder-game-launch-settings.sh` | Launch env wiring |

Shared helper contract (shell), used by apply + fast-edit:

```bash
# Face for target id
cyder_font_face_for_target() {
  case "$1" in
    mingliu) printf 'MingLiU\n' ;;
    jhenghei) printf 'Microsoft JhengHei\n' ;;
    *) printf 'Songti TC\n' ;;
  esac
}
```

MingLiU-family keys (horizontal):  
`MingLiU` `PMingLiU` `細明體` `新細明體` `MS Shell Dlg` `MS Shell Dlg 2` `Microsoft Sans Serif`  
Vertical: `@PMingLiU` `@細明體` → value `@$face`

Songti-family keys:  
`SimSun` `NSimSun` `宋体` `新宋体`  
Vertical (include for completeness): `@SimSun` `@宋体` → `@$face`

---

### Task 1: Apply-settings dual targets (TDD)

**Files:**
- Modify: `scripts/cyder-apply-settings.sh`
- Modify: `tests/test-cyder-settings.sh`
- Optional shared snippet: keep helpers inline in the script (no new file unless duplication with fast-edit becomes painful in Task 2)

**Interfaces:**
- Consumes: `CYDER_FONT_MINGLIU_TARGET`, `CYDER_FONT_SONGTI_TARGET` (and temporary accept legacy `CYDER_FONT_PRESET` for one release: map like migration table)
- Produces: registry ops under `HKCU\Software\Wine\Fonts\Replacements`; ledger keys `font-<Name>` = face or `absent`; deletes `Replacements(disabled)` if present

- [ ] **Step 1: Rewrite failing expectations in `tests/test-cyder-settings.sh`**

Replace the mingliu block that asserts section rename with dual-target assertions:

```bash
export CYDER_RETINA_MODE=0 CYDER_DPI=144
export CYDER_FONT_MINGLIU_TARGET=mingliu
export CYDER_FONT_SONGTI_TARGET=songti
export CYDER_FONT_SMOOTHING=grayscale
unset CYDER_FONT_PRESET || true
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
output="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$output" "RetinaMode /t REG_SZ /d n" "Retina off should be explicit"
assert_contains "$output" "LogPixels /t REG_DWORD /d 144" "selected DPI should be applied"
assert_contains "$output" "FontSmoothingType /t REG_DWORD /d 1" "grayscale smoothing should be applied"
# MingLiU family: delete replacements (no whole-key disable)
assert_contains "$output" "Fonts\\Replacements /v MingLiU" "MingLiU replacement should be deleted or targeted"
# Prefer explicit delete in mock log:
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\Fonts\\Replacements /v MingLiU" \
  "mingliu target should delete MingLiU replacement"
assert_contains "$output" "reg add HKCU\\Software\\Wine\\Fonts\\Replacements /v SimSun /t REG_SZ /d Songti TC" \
  "songti family should still map SimSun to Songti TC"
if [[ "$output" == *"Replacements(disabled)"* ]]; then
  echo "ASSERT failed: must not rename Replacements to (disabled)" >&2
  exit 1
fi
```

Also update later blocks that export `CYDER_FONT_PRESET=songti` to:

```bash
export CYDER_FONT_MINGLIU_TARGET=songti CYDER_FONT_SONGTI_TARGET=songti
```

Add a new jhenghei case near the end:

```bash
: >"$CYDER_TEST_WINE_LOG"
rm -f "$TMP/prefix/.cyder-settings-applied.tsv"
export CYDER_FONT_MINGLIU_TARGET=jhenghei CYDER_FONT_SONGTI_TARGET=mingliu
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
jh="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$jh" 'Fonts\\Replacements /v MingLiU /t REG_SZ /d Microsoft JhengHei' \
  "jhenghei should map MingLiU to Microsoft JhengHei"
assert_contains "$jh" 'Fonts\\Replacements /v SimSun /t REG_SZ /d MingLiU' \
  "songti→mingliu should map SimSun to MingLiU"
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash tests/test-cyder-settings.sh`  
Expected: FAIL (unknown env / old rename behavior)

- [ ] **Step 3: Implement `cyder-apply-settings.sh` font section**

Replace the `font=…` / `move_key_if_present` block with roughly:

```bash
mingliu_target="${CYDER_FONT_MINGLIU_TARGET:-}"
songti_target="${CYDER_FONT_SONGTI_TARGET:-}"
# Legacy bridge
if [[ -z "$mingliu_target" || -z "$songti_target" ]]; then
  legacy="${CYDER_FONT_PRESET:-songti}"
  case "$legacy" in
    mingliu) mingliu_target="${mingliu_target:-mingliu}"; songti_target="${songti_target:-songti}" ;;
    *) mingliu_target="${mingliu_target:-songti}"; songti_target="${songti_target:-songti}" ;;
  esac
fi
case "$mingliu_target" in mingliu|songti|jhenghei) ;; *) mingliu_target=songti ;; esac
case "$songti_target" in mingliu|songti|jhenghei) ;; *) songti_target=songti ;; esac

face_for() {
  case "$1" in mingliu) printf 'MingLiU' ;; jhenghei) printf 'Microsoft JhengHei' ;; *) printf 'Songti TC' ;; esac
}

font_key='HKCU\Software\Wine\Fonts\Replacements'
# Ensure active key exists / drop disabled leftover
delete_reg_if_changed font-disabled-section absent \
  'HKCU\Software\Wine\Fonts\Replacements(disabled)' /f || true
# (If delete_reg_if_changed is awkward for whole keys, call wine reg delete once when CYDER_FORCE or state differs.)

apply_family() {
  local target="$1"; shift
  local face vertical_face name
  face="$(face_for "$target")"
  vertical_face="@$face"
  for name in "$@"; do
    if [[ "$target" == mingliu && "$1" == __MINGLIU_FAMILY__ ]]; then
      : # handled by caller split
    fi
  done
}
```

Cleaner concrete loop (no placeholder flags):

```bash
ming_face="$(face_for "$mingliu_target")"
song_face="$(face_for "$songti_target")"

# Always keep Replacements active: if disabled section exists, copy to active then delete disabled (force once).
if [[ "${CYDER_FORCE_SETTINGS:-0}" == 1 ]] || [[ "$(state_value font-disabled-section 2>/dev/null || true)" != absent ]]; then
  "${WINE[@]}" reg delete 'HKCU\Software\Wine\Fonts\Replacements(disabled)' /f 2>/dev/null || true
  state_update font-disabled-section absent
fi

for name in MingLiU PMingLiU 細明體 新細明體 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
  if [[ "$mingliu_target" == mingliu ]]; then
    delete_reg_if_changed "font-$name" absent delete "$font_key" /v "$name" /f
  else
    apply_reg_if_changed "font-$name" "$ming_face" add "$font_key" /v "$name" /t REG_SZ /d "$ming_face" /f
  fi
done
for name in @PMingLiU @細明體; do
  if [[ "$mingliu_target" == mingliu ]]; then
    delete_reg_if_changed "font-$name" absent delete "$font_key" /v "$name" /f
  else
    apply_reg_if_changed "font-$name" "@$ming_face" add "$font_key" /v "$name" /t REG_SZ /d "@$ming_face" /f
  fi
done

for name in SimSun NSimSun 宋体 新宋体; do
  apply_reg_if_changed "font-$name" "$song_face" add "$font_key" /v "$name" /t REG_SZ /d "$song_face" /f
done
for name in @SimSun @宋体; do
  apply_reg_if_changed "font-$name" "@$song_face" add "$font_key" /v "$name" /t REG_SZ /d "@$song_face" /f
done
```

Rewrite the final state_tmp dump similarly (per-key face/`absent`, plus `font-mingliu-target` / `font-songti-target`). Remove `font-section` ledger entries.

Note: `delete_reg_if_changed` currently treats success of `reg delete` — ensure mock wine records `reg delete …` so tests see it. If delete fails when missing, still `state_update` to absent when exit 0 or when wine mock always succeeds.

- [ ] **Step 4: Run `bash tests/test-cyder-settings.sh` — expect PASS**

- [ ] **Step 5: Commit (only if user requested commits)**

```bash
git add scripts/cyder-apply-settings.sh tests/test-cyder-settings.sh
git commit -m "$(cat <<'EOF'
feat: apply dual MingLiU/Songti font replacement targets

EOF
)"
```

---

### Task 2: Fast user.reg editor

**Files:**
- Modify: `scripts/cyder-edit-user-reg.sh`
- Modify: `tests/test-cyder-fast-user-reg.sh`

**Interfaces:**
- Consumes: same env vars as Task 1; `CYDER_FAST_SETTING=font|font-mingliu|font-songti|all`
- Produces: in-place `user.reg` with active `Replacements` section and correct values

- [ ] **Step 1: Update `tests/test-cyder-fast-user-reg.sh`**

```bash
WINEPREFIX="$TMP/prefix" \
  CYDER_FONT_MINGLIU_TARGET=mingliu CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FAST_SETTING=font \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements]' "Replacements stay active"
if [[ "$reg" == *'[Software\\Wine\\Fonts\\Replacements(disabled)]'* ]]; then
  echo "ASSERT failed: disabled section should be removed" >&2
  exit 1
fi
# MingLiU line should be gone
if echo "$reg" | grep -q '^"MingLiU"='; then
  echo "ASSERT failed: MingLiU replacement should be deleted" >&2
  exit 1
fi
assert_contains "$reg" '"SimSun"="Songti TC"' "SimSun should map to Songti TC"
# seed SimSun in fixture if missing — extend initial user.reg fixture accordingly

WINEPREFIX="$TMP/prefix" \
  CYDER_FONT_MINGLIU_TARGET=jhenghei CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FAST_SETTING=font-mingliu \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"MingLiU"="Microsoft JhengHei"' "fast mingliu path sets JhengHei"
```

Extend the initial fixture `user.reg` to include `SimSun` and ensure sed helpers can insert missing values (not only substitute).

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash tests/test-cyder-fast-user-reg.sh`

- [ ] **Step 3: Implement sed helpers in `cyder-edit-user-reg.sh`**

Required behavior:

1. Rename `Replacements(disabled)` → `Replacements` if needed; if both exist, delete disabled block.
2. Within `[Software\\Wine\\Fonts\\Replacements]…` section:
   - `set_reg_sz NAME VALUE` — replace existing `"NAME"=…` or insert before next `[` section.
   - `del_reg_sz NAME` — delete the line if present.
3. `apply_font_mingliu` / `apply_font_songti` / `apply_font` (both).
4. Log line includes both targets:

```bash
echo "Applied Cyder $SETTING … fontMingLiu=$mingliu_target fontSongti=$songti_target smoothing=$smoothing)"
```

Insertion approach (BSD sed): if substitute did not match, use a small Python/perl one-liner **only if** the repo already uses that pattern; otherwise prefer a bash while-read rewrite of the section. Keep dependency-free: pure bash rewrite is fine.

Minimal pure-bash sketch:

```bash
rewrite_replacements_section() {
  # reads USER_REG, writes temp with updated keys from assoc lists
  …
}
```

- [ ] **Step 4: Run `bash tests/test-cyder-fast-user-reg.sh` — expect PASS**

- [ ] **Step 5: Commit if requested**

```bash
git add scripts/cyder-edit-user-reg.sh tests/test-cyder-fast-user-reg.sh
git commit -m "$(cat <<'EOF'
feat: fast-edit dual font replacement keys in user.reg

EOF
)"
```

---

### Task 3: Settings model + shell env (schema 8)

**Files:**
- Modify: `scripts/cyder_settings.swift`
- Modify: `scripts/cyder-common.sh`
- Modify: `tests/test-cyder-game-launch-settings.sh`
- Modify: `scripts/cyder-apply-golden-settings.sh`
- Modify: `scripts/cyder-songti-replacements.reg`

**Interfaces:**
- Produces: `CyderSettings.fontMingLiuTarget` / `fontSongtiTarget`; `CyderExecutableSettings` optional overrides; `environment` exports new vars; `schemaVersion = 8`
- Consumes: legacy `fontPreset` on decode only

- [ ] **Step 1: Add a small decode migration unit via existing patterns**

If there is no Swift XCTest target, add a bash test that builds a tiny swift snippet **only if** the repo already does that; otherwise cover migration indirectly by asserting JSON round-trip in a new `tests/test-cyder-settings-schema.sh` that runs `swift` against a here-doc — skip if too heavy.

Prefer: extend `test-cyder-game-launch-settings.sh` env expectations, and add JSON fixture assertions using `plutil`/`python3` on a temp settings file written by a minimal swift run **if** `scripts/cyder_settings.swift` is already compiled into the app only.

Practical approach used in this repo: keep migration logic in Swift and assert string contracts:

```bash
# tests/test-cyder-force-settings-ui.sh or new test-cyder-settings-model.sh
settings="$(cat "$ROOT/scripts/cyder_settings.swift")"
assert_contains "$settings" 'fontMingLiuTarget' "schema should store MingLiU target"
assert_contains "$settings" 'fontSongtiTarget' "schema should store Songti target"
assert_contains "$settings" 'schemaVersion = 8' "schema version 8"
assert_contains "$settings" 'CYDER_FONT_MINGLIU_TARGET' "env export MingLiU target"
assert_contains "$settings" 'CYDER_FONT_SONGTI_TARGET' "env export Songti target"
```

Add these asserts in Step 4’s UI/model test file; for Step 1 write them into `tests/test-cyder-settings-model.sh` (new) and run to FAIL.

- [ ] **Step 2: Run new model contract test — FAIL**

- [ ] **Step 3: Implement Swift + shell**

In `CyderSettings`:

```swift
var fontMingLiuTarget = cyderDefaultMingLiuFontTarget()
var fontSongtiTarget = "songti"
// remove stored reliance on fontPreset; keep private migration:
static func migrateFontTargets(preset: String?) -> (String, String) {
    switch preset {
    case "mingliu": return ("mingliu", "songti")
    default: return (cyderDefaultMingLiuFontTarget(), "songti")
    // when preset == songti: ("songti", "songti") — defaultMingLiu when nil uses detect
    }
}
```

Clarify decode:

```swift
let legacyPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset)
let migrated = Self.migrateFontTargets(preset: legacyPreset)
fontMingLiuTarget = try values.decodeIfPresent(String.self, forKey: .fontMingLiuTarget) ?? migrated.0
fontSongtiTarget = try values.decodeIfPresent(String.self, forKey: .fontSongtiTarget) ?? migrated.1
// If both new keys absent and preset == songti → ("songti","songti")
```

```swift
func cyderDefaultMingLiuFontTarget() -> String {
    cyderSystemProvidesMingLiU() ? "mingliu" : "songti"
}
func cyderSanitizeFontTarget(_ raw: String?) -> String {
    guard let raw, ["mingliu","songti","jhenghei"].contains(raw) else {
        return cyderDefaultMingLiuFontTarget() // for mingliu field callers pass default separately
    }
    return raw
}
```

Use `songti` as sanitize fallback for songti field.

`CodingKeys`: add new keys; keep `fontPreset` for decode-only (do not encode). Implement custom `encode(to:)` if needed so writes omit `fontPreset`.

`environment`:

```swift
"CYDER_FONT_MINGLIU_TARGET": value.fontMingLiuTarget,
"CYDER_FONT_SONGTI_TARGET": value.fontSongtiTarget,
```

Remove `CYDER_FONT_PRESET`. Profile overrides: `fontMingLiuTarget` / `fontSongtiTarget` optionals.

`cyder-common.sh`: mirror detect/export/plutil extract for both keys; profile JSON keys; stop exporting `CYDER_FONT_PRESET` except optional legacy read.

Update `cyder-songti-replacements.reg`:

```reg
REGEDIT4
[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"SimSun"="Songti TC"
"NSimSun"="Songti TC"
"宋体"="Songti TC"
"新宋体"="Songti TC"
"@SimSun"="@Songti TC"
"@宋体"="@Songti TC"
"MingLiU"="Songti TC"
"PMingLiU"="Songti TC"
"細明體"="Songti TC"
"新細明體"="Songti TC"
"MS Shell Dlg"="Songti TC"
"MS Shell Dlg 2"="Songti TC"
"Microsoft Sans Serif"="Songti TC"
"@PMingLiU"="@Songti TC"
"@細明體"="@Songti TC"
```

(Bootstrap still installs songti/songti defaults; later apply-settings reconciles to user settings.)

Golden script: set both targets in registry + state file.

- [ ] **Step 4: Update `test-cyder-game-launch-settings.sh` to expect new env vars; run model + launch tests — PASS**

- [ ] **Step 5: Commit if requested**

---

### Task 4: Settings UI + game library UI

**Files:**
- Modify: `scripts/cyder_settings_ui.swift`
- Modify: `scripts/cyder_game_library_ui.swift`
- Modify: `tests/test-cyder-force-settings-ui.sh`
- Modify: `docs/workarounds/font-default.md`

**Interfaces:**
- Consumes: `fontMingLiuTarget` / `fontSongtiTarget` from settings store
- Produces: `saveImmediately(registrySetting: "font-mingliu"|"font-songti"|"font")`

- [ ] **Step 1: Update UI contract tests**

In `tests/test-cyder-force-settings-ui.sh`:

```bash
assert_contains "$ui" '細明體取代' "global UI should label MingLiU replacement"
assert_contains "$ui" '宋體取代' "global UI should label Songti replacement"
assert_contains "$ui" '微軟正黑體' "UI should offer Microsoft JhengHei"
assert_contains "$ui" 'saveImmediately(registrySetting: "font-mingliu")' \
  "MingLiU popup should fast-apply mingliu family"
assert_contains "$ui" 'saveImmediately(registrySetting: "font-songti")' \
  "Songti popup should fast-apply songti family"
assert_contains "$library_ui" '細明體取代' "game settings should label MingLiU replacement"
assert_contains "$library_ui" '宋體取代' "game settings should label Songti replacement"
# Remove/replace old single-font assertions about fontPreset index 1 mingliu
```

- [ ] **Step 2: Run `bash tests/test-cyder-force-settings-ui.sh` — FAIL**

- [ ] **Step 3: Implement UI**

Shared option order (index 0…2): `mingliu`, `songti`, `jhenghei`  
Titles: `細明體`, `宋體`, `微軟正黑體`

Replace single `font` popup with `fontMingLiu` + `fontSongti` in:

- global advanced display/font section
- executable override editors in settings UI
- `CyderGameSettingsWindowController` in game library

Wire changes:

```swift
@objc private func fontMingLiuChanged() {
    saveImmediately(registrySetting: "font-mingliu")
}
@objc private func fontSongtiChanged() {
    saveImmediately(registrySetting: "font-songti")
}
```

Ensure `onImmediateSave` / launcher still pass `CYDER_FAST_SETTING` through unchanged (already generic).

Update `docs/workarounds/font-default.md` to describe two controls and the Songti-family special case.

- [ ] **Step 4: Run UI + settings + fast-user-reg + game-launch tests — PASS**

```bash
bash tests/test-cyder-settings.sh
bash tests/test-cyder-fast-user-reg.sh
bash tests/test-cyder-force-settings-ui.sh
bash tests/test-cyder-game-launch-settings.sh
```

- [ ] **Step 5: Commit if requested**

```bash
git add scripts/cyder_settings_ui.swift scripts/cyder_game_library_ui.swift \
  tests/test-cyder-force-settings-ui.sh docs/workarounds/font-default.md
git commit -m "$(cat <<'EOF'
feat: expose dual font replacement controls in Cyder UI

EOF
)"
```

---

### Task 5: Spec status + residual cleanup

**Files:**
- Modify: `docs/superpowers/specs/2026-08-04-dual-font-replacements-design.md` (status → implemented)
- Grep leftover `CYDER_FONT_PRESET` / `fontPreset` in scripts & tests; fix stragglers (`install-cyder-font-replacements.sh` message text OK to keep “Songti” as bootstrap default)
- Confirm `tests/test-cyder-bootstrap.sh` still valid (PMingLiU may still be Songti TC after bootstrap)

- [ ] **Step 1: `rg -n 'CYDER_FONT_PRESET|fontPreset|Replacements\\(disabled\\)' scripts tests` and fix leftovers**

- [ ] **Step 2: Run full focused suite**

```bash
bash tests/test-cyder-settings.sh
bash tests/test-cyder-fast-user-reg.sh
bash tests/test-cyder-force-settings-ui.sh
bash tests/test-cyder-game-launch-settings.sh
bash tests/test-cyder-bootstrap.sh  # skip OK if no local wine
```

- [ ] **Step 3: Mark spec status implemented; commit if requested**

---

## Spec coverage self-check

| Spec item | Task |
|-----------|------|
| Dual fields + schema 8 + migration | 3 |
| Family key lists + faces | 1–2 |
| MingLiU→mingliu deletes; Songti→songti writes Songti TC | 1–2 |
| Shell Dlg in MingLiU family | 1–2 |
| JhengHei writes without install check | 1–4 |
| Fast settings `font-mingliu` / `font-songti` | 2, 4 |
| UI two popups | 4 |
| Docs | 4 |
| Drop `(disabled)` whole-key scheme | 1–2 |
| Bootstrap `.reg` dual defaults | 3 |
| Non-goals (no PingFang, no font shipping) | honored throughout |

## Placeholder scan

No TBD/TODO left in task steps; open bootstrap detail resolved as “update `.reg` + apply-settings remains runtime source of truth”.
