# Bootstrap P3/P4/P5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Structured bootstrap progress, idempotent component skips, and graphics/winemetal only after the prefix exists.

**Architecture:** Extend `cyder_report_progress` + Swift progress reader; gate Mono/Gecko/tar/golden installs on markers; remove pre-bootstrap graphics prepare from shared bootstrap.

**Tech Stack:** Bash (`cyder-common.sh`), Swift (`cyder_app_main.swift`), shell tests.

## Global Constraints

- Keep Phase C failure fatal for this round.
- Preserve plain-text progress compatibility.
- Do not force wineserver `-p`.

---

### Task 1: P3 progress contract tests + implement

**Files:**
- Modify: `scripts/cyder-common.sh`
- Modify: `scripts/cyder_app_main.swift`
- Modify/add: `tests/test-cyder-bootstrap-timing.sh` or focused progress test
- Modify: `tests/test-cyder-open-files-lifecycle.sh` if needed for Swift parser

- [ ] Assert progress writes `stage=` / `label=`
- [ ] Assert Swift parses structured progress and formats elapsed
- [ ] Implement shell + Swift
- [ ] Run tests

### Task 2: P4 idempotent skip

**Files:**
- Modify: `scripts/cyder-common.sh` (`cyder_provision_prefix_baseline`)
- Modify: `tests/test-cyder-bootstrap-timing.sh` / template bootstrap tests

- [ ] Assert skip conditions for mono/gecko/tar/golden markers
- [ ] Implement skips with progress “已就緒，略過…”
- [ ] Run tests

### Task 3: P5 graphics decouple

**Files:**
- Modify: `scripts/cyder-common.sh` (`cyder_bootstrap_shared_prefix`)
- Modify: relevant launcher/template tests

- [ ] Assert shared bootstrap does not prepare graphics before provision
- [ ] Keep post-provision `cyder_ensure_graphics`
- [ ] Run launcher + template bootstrap tests

### Task 4: Verify

- [ ] `test-cyder-bootstrap-timing.sh`
- [ ] `test-cyder-wineboot-logging.sh`
- [ ] `test-cyder-launcher.sh`
- [ ] `test-cyder-template-bootstrap.sh`
- [ ] `test-cyder-open-files-lifecycle.sh` (if Swift touched)
