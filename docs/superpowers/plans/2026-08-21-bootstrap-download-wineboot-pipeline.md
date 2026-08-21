# Bootstrap Download∥Wineboot Pipeline Implementation Plan

> **Status: superseded (2026-08-21)** — Mono/Gecko download/install scheduler removed from bootstrap (`a19c783`). Do not re-implement against this plan without a new approved design.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parallelize mono/gecko MSI download with wineboot, then install whichever component is ready first under a single-install mutex (scheme B).

**Architecture:** In `cyder_provision_prefix_baseline`, start both `--download-only` jobs in the background (record timing via `cyder_bootstrap_substage_record` with explicit t0, not nested stage stack), run wineboot concurrently, then a scheduler loop reaps downloads and runs at most one msiexec at a time in ready order.

**Tech Stack:** bash (`cyder-common.sh`), existing install scripts, bootstrap-timing.jsonl, shell contract tests.

## Global Constraints

- Preserve P2: no download/checksum work on the msiexec hot path after the component’s MSI is ready; no dual concurrent msiexec; no `wineserver -p`.
- Scheme B: install order follows readiness (tie-break: prefer Mono if both ready in the same loop iteration).
- Do not mutate live bottle in tests; dry-run uses isolated `CYDER_SUPPORT`.
- Update contract tests that currently require serial “download before wineboot” source order.

---

### Task 1: Pipeline in `cyder_provision_prefix_baseline`

**Files:**
- Modify: `scripts/cyder-common.sh` (`cyder_provision_prefix_baseline`)
- Modify: `tests/test-cyder-bootstrap-timing.sh` (parallel contract)

**Interfaces:**
- Consumes: `install-wine-mono.sh` / `install-wine-gecko.sh` `--download-only`, `cyder_init_bottle`, `cyder_bootstrap_substage_*`
- Produces: same markers / `CYDER_BOOTSTRAP_HEALTH_CHECKED=1` on success; overlapping download/wineboot spans in timing jsonl

- [ ] **Step 1: Replace serial download→wineboot→install with pipeline**

Replace the block from “Prefetch MSIs before wineboot…” through gecko-install with:

1. Validate install scripts exist (unchanged).
2. If mono marker missing: start bg `--download-only`, save `mono_dl_pid` + `mono_dl_t0`; else mark mono done/skipped.
3. Same for gecko.
4. Run wineboot (`cyder_init_bottle`) with normal begin/end; on failure kill download PIDs, end open download records if needed, return.
5. Scheduler loop until both components installed/skipped:
   - Reap finished download PIDs; `cyder_bootstrap_substage_record` with `now - t0`; non-zero → kill sibling, stop wineserver, return.
   - If mono ready and not installed → mono-install (existing body).
   - Else if gecko ready and not installed → gecko-install.
   - Else if downloads still running → `sleep 0.2`.
   - Else → error return.
6. Keep tar / golden / verify unchanged.

Do **not** nest `cyder_bootstrap_substage_begin` for overlapping downloads with wineboot; use explicit t0 + `cyder_bootstrap_substage_record` (and optional diagnostic begin printf).

- [ ] **Step 2: Update `tests/test-cyder-bootstrap-timing.sh`**

Replace “download_before_wineboot must appear before wineboot begin” with:

- Provision starts downloads in background (`&` / `mono_dl_pid` or equivalent).
- Scheduler / install gated on download ready + wineboot.
- Assert no serial `bash ... --download-only` **blocking** call that must complete before `cyder_init_bottle` (i.e. wineboot is not preceded by waiting on both downloads).
- Keep: separate mono-download / gecko-download timing names; mono-install / gecko-install after wineboot path; skip markers; P3–P5 asserts.

- [ ] **Step 3: Run contract tests**

```bash
bash tests/test-cyder-bootstrap-timing.sh
bash tests/test-cyder-prefetch-bootstrap-msi.sh
```

Expected: PASS

- [ ] **Step 4: Commit only if user asks**

---

### Task 2: Dry-run measure and compare

**Files:**
- Runtime under `debug/cyder-first-open-prefs-*`
- Optional: update canvas with new numbers

- [ ] **Step 1: Run** `bash scripts/cyder-measure-first-open-preferences.sh`
- [ ] **Step 2: Confirm** download spans overlap wineboot; settings-ready improved vs ~38.5s baseline when network similar
- [ ] **Step 3: Summarize in Traditional Chinese**

---

## Plan self-review

1. Spec coverage: parallel dl∥wineboot, ready-order install, mutex, errors, skip markers, timing — covered.
2. No placeholders.
3. Tests updated for new contract.
