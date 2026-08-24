# Rosetta Consent Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Apple Silicon, Cyder shows an informed-consent dialog for Rosetta 2, installs with `--agree-to-license` only after the user accepts, shows `CyderSetupPanel` progress, and continues only on success (`CYD-ROS-001` on cancel/failure).

**Architecture:** Swift owns detect → consent → progress → `softwareupdate --install-rosetta --agree-to-license` → verify, at the start of `ensureEnvironment`. Bash under `CYDER_GUI=1` is check-only (no install, no TTY hang). CLI keeps interactive install without agree.

**Tech Stack:** AppKit (`NSAlert`, `CyderSetupPanel`), Foundation `Process`, bash (`cyder-ensure-rosetta.sh`), shell contract tests.

**Spec:** `docs/superpowers/specs/2026-08-25-rosetta-consent-install-design.md`

## Global Constraints

- Traditional Chinese user-facing strings.
- Consent copy must state: Apple official component, needed for x86_64, installing will accept Apple’s license on the user’s behalf.
- Error code **`CYD-ROS-001`**; stage **`rosetta-check`**.
- GUI must never call `softwareupdate --install-rosetta` without prior Cyder consent + `--agree-to-license`.
- Bash `CYDER_GUI=1`: check only; missing Rosetta → fail with clear message (no install).
- CLI / non-GUI: interactive `softwareupdate --install-rosetta` (no `--agree-to-license`).
- Reuse `CyderSetupPanel` indeterminate progress (no percent).
- Conventional Commits; do not rewrite historical v0.9.0 notes; update current release notes (`docs/releases/v0.13.0.md` or newer shipping version).
- Prefer TDD: update `tests/test-cyder-rosetta.sh` before / with production changes.

## File map

| File | Responsibility |
|------|----------------|
| `scripts/cyder_rosetta.swift` (new) | Detect Apple Silicon / Rosetta installed; run consented install |
| `scripts/cyder_diagnostics.swift` | Add `CyderStage.rosettaCheck` |
| `scripts/cyder_app_main.swift` | Consent alert + setup panel + gate at start of `ensureEnvironment` |
| `scripts/create-cyder-app.sh` | Compile `cyder_rosetta.swift` |
| `scripts/cyder-ensure-rosetta.sh` | GUI check-only; CLI interactive install |
| `tests/test-cyder-rosetta.sh` | Contract tests for bash + Swift |
| `docs/cyder.md` | Document App consent path vs CLI |
| `docs/releases/v0.13.0.md` (or current) | Release note |
| Spec | Mark design implemented when done |

---

### Task 1: Bash GUI check-only + contract tests

**Files:**
- Modify: `scripts/cyder-ensure-rosetta.sh`
- Modify: `tests/test-cyder-rosetta.sh`
- Test: `tests/test-cyder-rosetta.sh`

**Interfaces:**
- Produces: `cyder_ensure_rosetta` under `CYDER_GUI=1` never runs `softwareupdate`; CLI still may run interactive install without `--agree-to-license`.

- [ ] **Step 1: Rewrite the contract test**

Replace `tests/test-cyder-rosetta.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-ensure-rosetta.sh"

rosetta_script="$(<"$ROOT/scripts/cyder-ensure-rosetta.sh")"
assert_contains "$rosetta_script" "/usr/sbin/softwareupdate --install-rosetta" \
  "Rosetta installation must use the macOS installer"
assert_contains "$rosetta_script" 'CYDER_GUI' \
  "Rosetta ensure must branch on CYDER_GUI"
# Bash must not pass --agree-to-license (Swift owns consented install).
if [[ "$rosetta_script" == *"--agree-to-license"* ]]; then
  echo "ASSERT failed: bash must not --agree-to-license; Swift owns consent install" >&2
  exit 1
fi

ensure_fn="$(sed -n '/^cyder_ensure_rosetta()/,/^}/p' "$ROOT/scripts/cyder-ensure-rosetta.sh")"
assert_contains "$ensure_fn" 'CYDER_GUI' \
  "ensure must treat GUI differently from CLI"
assert_contains "$ensure_fn" 'return 1' \
  "GUI missing-Rosetta path must fail without installing"

if cyder_is_apple_silicon; then
  if ! cyder_rosetta_is_installed; then
    echo "SKIP: Rosetta 2 not installed (cannot run the OS installer in this test)"
    exit 0
  fi
  cyder_ensure_rosetta
  echo "Rosetta check OK on Apple Silicon"
else
  cyder_ensure_rosetta
  echo "Rosetta check skipped on $(uname -m)"
fi

set +e
status="$(
  CYDER_GUI=1 bash "$ROOT/scripts/cyder_launcher.sh" --ensure-rosetta-only >/dev/null 2>&1
  echo $?
)"
set -e
assert_eq "$status" "0" "--ensure-rosetta-only should succeed when Rosetta is available"

echo "PASS test-cyder-rosetta"
```

- [ ] **Step 2: Run test (expect fail until bash updated)**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: FAIL on `CYDER_GUI` branching (or similar).

- [ ] **Step 3: Implement bash GUI check-only**

Replace `scripts/cyder-ensure-rosetta.sh` with:

```bash
#!/usr/bin/env bash
# Ensure Rosetta 2 is available on Apple Silicon before running x86_64 Wine.
set -euo pipefail

cyder_is_apple_silicon() {
  [[ "$(uname -m)" == "arm64" ]]
}

cyder_rosetta_is_installed() {
  if /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    return 0
  fi
  arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

cyder_rosetta_install_interactive() {
  # CLI / non-GUI only. Do not pass --agree-to-license; Swift owns consented GUI install.
  /usr/sbin/softwareupdate --install-rosetta
}

cyder_rosetta_error() {
  local message="$1"
  if [[ "${CYDER_GUI:-0}" == 1 ]]; then
    osascript -e "display alert \"Cyder 需要 Rosetta 2\" message \"$message\" as warning" 2>/dev/null || true
  else
    echo "$message" >&2
  fi
}

cyder_ensure_rosetta() {
  if ! cyder_is_apple_silicon; then
    return 0
  fi
  if cyder_rosetta_is_installed; then
    return 0
  fi

  # AppKit path installs Rosetta after informed consent. Never run softwareupdate
  # from GUI bash (no TTY for license; would hang or mis-report as engine errors).
  if [[ "${CYDER_GUI:-0}" == 1 ]]; then
    cyder_rosetta_error "請先在 Cyder 對話框同意並完成 Rosetta 2 安裝。"
    return 1
  fi

  echo "Rosetta 2 is required; installing it with softwareupdate..." >&2
  if ! cyder_rosetta_install_interactive; then
    cyder_rosetta_error "請先安裝 Rosetta 2，Cyder 才能執行 x86_64 Wine 引擎。"
    return 1
  fi

  if ! cyder_rosetta_is_installed; then
    cyder_rosetta_error "Rosetta 2 安裝未完成，請重新啟動 Cyder。"
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Re-run test**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: `PASS test-cyder-rosetta` (or SKIP if Rosetta missing on Silicon).

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder-ensure-rosetta.sh tests/test-cyder-rosetta.sh
git commit -m "$(cat <<'EOF'
fix(launcher): make GUI Rosetta path check-only

EOF
)"
```

---

### Task 2: Swift Rosetta helper + stage + build wiring + contracts

**Files:**
- Create: `scripts/cyder_rosetta.swift`
- Modify: `scripts/cyder_diagnostics.swift`
- Modify: `scripts/create-cyder-app.sh`
- Modify: `tests/test-cyder-rosetta.sh`
- Test: `tests/test-cyder-rosetta.sh`

**Interfaces:**
- Produces:
  - `CyderStage.rosettaCheck = "rosetta-check"`
  - `enum CyderRosetta` with `isAppleSilicon`, `isInstalled`, `installWithAgreedLicense() -> (ok: Bool, detail: String)`

- [ ] **Step 1: Append Task 2 contract assertions** to `tests/test-cyder-rosetta.sh` (before final `PASS`):

```bash
rosetta_swift="$(cat "$ROOT/scripts/cyder_rosetta.swift")"
assert_contains "$rosetta_swift" '/usr/sbin/softwareupdate' \
  "Swift Rosetta helper must invoke softwareupdate"
assert_contains "$rosetta_swift" '--agree-to-license' \
  "Swift consented install must pass --agree-to-license"
assert_contains "$rosetta_swift" 'static var isInstalled' \
  "Swift must expose Rosetta installed check"

diag="$(cat "$ROOT/scripts/cyder_diagnostics.swift")"
assert_contains "$diag" 'case rosettaCheck = "rosetta-check"' \
  "diagnostics must define rosetta-check stage"

build="$(cat "$ROOT/scripts/create-cyder-app.sh")"
assert_contains "$build" 'cyder_rosetta.swift' \
  "app build must compile cyder_rosetta.swift"
```

- [ ] **Step 2: Run test — expect fail**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: FAIL (missing `cyder_rosetta.swift` / `rosettaCheck`).

- [ ] **Step 3: Add stage** in `scripts/cyder_diagnostics.swift` inside `enum CyderStage`:

```swift
    case rosettaCheck = "rosetta-check"
```

- [ ] **Step 4: Create `scripts/cyder_rosetta.swift`**

```swift
import Foundation

enum CyderRosetta {
    static var isAppleSilicon: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
        process.arguments = ["-m"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let machine = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return machine == "arm64"
    }

    static var isInstalled: Bool {
        let pkg = Process()
        pkg.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        pkg.arguments = ["--pkg-info", "com.apple.pkg.RosettaUpdateAuto"]
        pkg.standardOutput = FileHandle.nullDevice
        pkg.standardError = FileHandle.nullDevice
        do {
            try pkg.run()
            pkg.waitUntilExit()
            if pkg.terminationStatus == 0 { return true }
        } catch {}

        let arch = Process()
        arch.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        arch.arguments = ["-x86_64", "/usr/bin/true"]
        arch.standardOutput = FileHandle.nullDevice
        arch.standardError = FileHandle.nullDevice
        do {
            try arch.run()
            arch.waitUntilExit()
            return arch.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Caller must have obtained informed consent in the UI.
    static func installWithAgreedLicense() -> (ok: Bool, detail: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["--install-rosetta", "--agree-to-license"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "failed to start softwareupdate: \(error.localizedDescription)")
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let combined = String(data: outData + errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return (false, combined.isEmpty
                ? "softwareupdate exit \(process.terminationStatus)"
                : combined)
        }
        if !isInstalled {
            return (false, combined.isEmpty
                ? "Rosetta install reported success but verification failed"
                : combined)
        }
        return (true, combined)
    }
}
```

- [ ] **Step 5: Wire build** — in `scripts/create-cyder-app.sh` `SWIFT_SOURCES`, add after `cyder_launch_support.swift`:

```bash
  "$SCRIPT_DIR/cyder_rosetta.swift"
```

- [ ] **Step 6: Run test**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/cyder_rosetta.swift scripts/cyder_diagnostics.swift \
  scripts/create-cyder-app.sh tests/test-cyder-rosetta.sh
git commit -m "$(cat <<'EOF'
feat(app): add Swift Rosetta detect and consented install helper

EOF
)"
```

---

### Task 3: Gate `ensureEnvironment` with consent UI

**Files:**
- Modify: `scripts/cyder_app_main.swift`
- Modify: `tests/test-cyder-rosetta.sh`
- Test: `tests/test-cyder-rosetta.sh`

**Interfaces:**
- Consumes: `CyderRosetta`, `CyderStage.rosettaCheck`, `showSetup` / `hideSetup`, `runFrontmostAlert`
- Produces: `ensureRosettaForEnvironment() -> CyderFailure?` at top of `ensureEnvironment`

- [ ] **Step 1: Append app contract assertions** to `tests/test-cyder-rosetta.sh`:

```bash
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$app" 'CYD-ROS-001' \
  "app must surface CYD-ROS-001"
assert_contains "$app" '需要安裝 Rosetta 2' \
  "app must show consent title"
assert_contains "$app" 'ensureRosettaForEnvironment' \
  "ensureEnvironment must call Rosetta gate"
assert_contains "$app" 'installWithAgreedLicense' \
  "app must install only after consent path"
```

- [ ] **Step 2: Run test — expect fail**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: FAIL on `CYD-ROS-001` / `ensureRosettaForEnvironment`.

- [ ] **Step 3: Implement gate in `cyder_app_main.swift`**

Add:

```swift
private func ensureRosettaForEnvironment() -> CyderFailure? {
    guard CyderRosetta.isAppleSilicon else { return nil }
    if CyderRosetta.isInstalled { return nil }

    CyderDiagnostics.shared.enter(.rosettaCheck)
    let alert = NSAlert()
    alert.messageText = "需要安裝 Rosetta 2"
    alert.informativeText =
        "Rosetta 2 是 Apple 提供的官方元件，讓 Apple Silicon Mac 能執行 x86_64 程式。"
        + "Cyder 的遊戲執行元件需要它才能運作。"
        + "若繼續安裝，將代表你同意 Apple 的軟體授權條款。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "安裝")
    alert.addButton(withTitle: "取消")

    let response = runFrontmostAlert(alert, dockVisible: false)
    if response != .alertFirstButtonReturn {
        return CyderFailure(
            code: "CYD-ROS-001",
            stage: .rosettaCheck,
            summary: "使用者取消安裝 Rosetta 2。",
            technicalDetails: "user-cancelled-rosetta-install"
        )
    }

    showSetup("正在安裝 Rosetta 2…")
    let installResult: (ok: Bool, detail: String)
    if Thread.isMainThread {
        installResult = DispatchQueue.global(qos: .userInitiated).sync {
            CyderRosetta.installWithAgreedLicense()
        }
    } else {
        installResult = CyderRosetta.installWithAgreedLicense()
    }
    hideSetup()
    if !installResult.ok {
        return CyderFailure(
            code: "CYD-ROS-001",
            stage: .rosettaCheck,
            summary: "無法安裝或完成 Rosetta 2。請稍後再試，或在「終端機」手動安裝。",
            technicalDetails: installResult.detail
        )
    }
    return nil
}
```

At the start of `ensureEnvironment(context:)`:

```swift
private func ensureEnvironment(context: CyderLaunchContext) -> CyderFailure? {
    if let rosettaFailure = ensureRosettaForEnvironment() {
        return rosettaFailure
    }
    let state = environmentState(context: context)
    // ... existing body unchanged ...
}
```

Match existing `onMainThread` usage if `ensureEnvironment` already runs off-main; keep alert/setup on main.

- [ ] **Step 4: Run contract test**

Run: `bash tests/test-cyder-rosetta.sh`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/cyder_app_main.swift tests/test-cyder-rosetta.sh
git commit -m "$(cat <<'EOF'
feat(app): consent and install Rosetta before engine ensure

EOF
)"
```

---

### Task 4: Docs + spec status

**Files:**
- Modify: `docs/cyder.md`
- Modify: `docs/releases/v0.13.0.md` (or current shipping version)
- Modify: `docs/superpowers/specs/2026-08-25-rosetta-consent-install-design.md`

- [ ] **Step 1: Update `docs/cyder.md`** — App path: Swift consent → `--agree-to-license` → continue; cancel/fail → `CYD-ROS-001`. CLI may use interactive install. Clarify App-mediated vs raw `arch -x86_64` paths.

- [ ] **Step 2: Release notes** under 應用入口:

```markdown
- Apple Silicon 缺 Rosetta 2 時，Cyder 顯示知情同意對話框；同意後以
  `softwareupdate --install-rosetta --agree-to-license` 安裝並顯示進度，成功後才繼續
  準備引擎。取消或失敗回報 `CYD-ROS-001`（不再誤報為引擎解壓錯誤）。
```

- [ ] **Step 3: Spec status** → `狀態：implemented`

- [ ] **Step 4: Commit**

```bash
git add docs/cyder.md docs/releases/v0.13.0.md \
  docs/superpowers/specs/2026-08-25-rosetta-consent-install-design.md
git commit -m "$(cat <<'EOF'
docs: document Swift Rosetta consent install

EOF
)"
```

---

### Task 5: Manual verification checklist

- [ ] Machine **with** Rosetta: open Preferences → no consent dialog.
- [ ] `bash tests/test-cyder-rosetta.sh` → PASS.
- [ ] Optional: `bash scripts/create-cyder-app.sh` compiles with `cyder_rosetta.swift`.
- [ ] If Rosetta-less Silicon available: cancel → `CYD-ROS-001`; accept → progress → setup continues.

---

## Spec coverage self-check

| Spec requirement | Task |
|------------------|------|
| Swift consent dialog | Task 3 |
| `--agree-to-license` only after consent | Tasks 2–3 |
| `CyderSetupPanel` progress | Task 3 |
| Continue only on success | Task 3 |
| `CYD-ROS-001` | Task 3 |
| GUI bash check-only | Task 1 |
| CLI interactive without agree | Task 1 |
| Docs / release note | Task 4 |

## Consistency self-check

- Stage: `rosetta-check` / `CyderStage.rosettaCheck`
- Helper: `CyderRosetta.installWithAgreedLicense()`
- Gate: `ensureRosettaForEnvironment()`
- No TBD placeholders in tasks
