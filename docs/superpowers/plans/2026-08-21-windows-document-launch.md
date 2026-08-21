# Windows Document Launch (bat/cmd/lnk/reg) Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Finder can open `.bat`/`.cmd`/`.lnk`/`.reg` via Cyder in 0.13.0 using kind-specific Wine launches.

**Architecture:** Extend the existing exe/msi document-launch pipeline: Swift filters paths and picks `CyderWineLaunchTarget`; Bash launcher gets matching `--launch-*` flags; `cyder_run_wine_exe` branches on `CYDER_LAUNCH_TARGET_KIND`.

**Tech Stack:** Bash (`cyder_launcher.sh`, `cyder-common.sh`, wrapper), Swift AppKit, Info.plist, contract shell tests.

## Global Constraints

- Ship in **0.13.0** (rebuild + re-notarize after merge).
- Approach **B** only (no library tiles / mac launcher for these types).
- `.reg` refuses when shared prefix is busy (exit 75).
- cwd remains `dirname` of the document path before Wine exec.
- Conventional Commits; Traditional Chinese user-facing strings.
- TDD: update contract tests before production where practical.

---

## Task 1: Contract tests (RED)

**Files:** `tests/test-cyder-msi-launch.sh` (or new `tests/test-cyder-windows-documents.sh`), extend existing openFiles / payload tests if present.

- [ ] Assert launcher help mentions `--launch-script`, `--launch-lnk`, `--launch-reg`
- [ ] Assert `normalizeExePaths` / successor accepts bat/cmd/lnk/reg
- [ ] Assert Info.plist template lists those extensions
- [ ] Assert wrapper routes `*.bat`/`*.cmd`/`*.lnk`/`*.reg`
- [ ] Run tests → expect fail
- [ ] Commit: `test(app): contract Windows document launch kinds`

## Task 2: Bash launch kinds (GREEN)

**Files:** `scripts/cyder_launcher.sh`, `scripts/cyder-common.sh`

- [ ] Add resolve helpers and `--launch-script` / `--launch-lnk` / `--launch-reg`
- [ ] Extend `cyder_exec_game` for `script` (`cmd /c`), `link` (`start /wait /unix`), `reg` (`regedit /s`)
- [ ] Reg busy check mirrors MSI
- [ ] Run contract tests for launcher strings
- [ ] Commit: `feat(launcher): launch bat/cmd/lnk/reg documents`

## Task 3: Swift + plist + wrapper (GREEN)

**Files:** `scripts/cyder_launch_support.swift`, `scripts/cyder_app_main.swift`, `scripts/create-cyder-app.sh`, `scripts/cyder-macos-wrapper.sh`, tests

- [ ] Extend path filter + `CyderWineLaunchTarget`
- [ ] Wire `runWineThroughLauncher` args
- [ ] MSI-like busy alert for reg
- [ ] Document types in Info.plist
- [ ] Wrapper extension routing
- [ ] Commit: `feat(app): open bat/cmd/lnk/reg via Finder`

## Task 4: Docs + 0.13.0 notes

**Files:** `docs/cyder.md`, `docs/releases/v0.13.0.md`, optionally `docs/scripts.md`

- [ ] Document Finder open behavior and reg busy policy
- [ ] Commit: `docs(release): include Windows documents in 0.13.0`

## Task 5: Rebuild notarized 0.13.0

- [ ] `bash scripts/release-cyder.sh --channel release --version 0.13.0`
- [ ] Confirm Gatekeeper Notarized Developer ID
