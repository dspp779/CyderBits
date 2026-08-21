# Bootstrap wineserver keep-alive Implementation Plan

> **Status: superseded (2026-08-21)** — Mono/Gecko preinstall removed from bootstrap (`a19c783`). Artifact-ready wait remains; MSI warm-path goal does not.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep wineserver alive after successful wineboot so Mono/Gecko reuse the warm session.

**Architecture:** Replace success-path `wineserver -w` + `-k` in `cyder_init_bottle` with bounded artifact readiness polling. Failure cleanup and end-of-baseline stop remain unchanged.

**Tech Stack:** Bash (`cyder-common.sh`), existing bootstrap timing JSONL, shell tests.

## Global Constraints

- Do not prestart wineserver before wineboot.
- Do not change Mono/Gecko MSI install semantics beyond reconnecting to a live server.
- Keep `CYD-WINEBOOT-*` error codes and failure cleanup behavior.

---

### Task 1: Failing tests for keep-alive contract

**Files:**
- Modify: `tests/test-cyder-bootstrap-timing.sh` (or add focused asserts)
- Optionally: `tests/test-cyder-launcher.sh` / template bootstrap fakes if they assert `-k`

- [ ] Assert `cyder_init_bottle` success path does **not** call `wineserver -k`
- [ ] Assert success path waits on artifacts (or records `wineboot-artifact-wait` / equivalent), not `wineserver -w` exit-wait
- [ ] Assert failure path still documents `failure_cleanup=wineserver -k`
- [ ] Run tests; expect failure before implementation

### Task 2: Implement keep-alive in `cyder_init_bottle`

**Files:**
- Modify: `scripts/cyder-common.sh`

- [ ] After wineboot success, poll bottle artifacts with timeout (reuse `CYDER_WINESERVER_WAIT_TIMEOUT`)
- [ ] Time the wait as a nested bootstrap substage
- [ ] Remove success-path `wineserver -k`
- [ ] Keep failure-path `-k`/`-w`
- [ ] Re-run tests until green

### Task 3: Measure before/after

**Files:** none (runtime)

- [ ] Run isolated bootstrap with timing (local scripts, cached MSIs)
- [ ] Compare against baseline: wineboot 14.7s / wait 4.2s / mono 5.8s / gecko 3.0s
- [ ] Report timeline delta to user

### Task 4: Commit

- [ ] Conventional Commit: `perf(bootstrap): keep wineserver warm after wineboot`
