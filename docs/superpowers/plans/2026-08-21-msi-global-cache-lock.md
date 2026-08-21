# MSI global cache + download lock — Implementation Plan

> **For agentic workers:** Use executing-plans / inline execution.

**Goal:** Point `CYDER_DOWNLOADS` at a global Cyder cache and serialize per-file MSI downloads with `mkdir` locks.

**Done when:** `tests/test-cyder-download-locked.sh` passes; mono/gecko source `cyder-download-locked.sh`; `create-cyder-app.sh` packs the helper.

## Tasks

1. Add `scripts/cyder-download-locked.sh` + wire mono/gecko + `cyder_init_paths` + pack script.
2. Add `tests/test-cyder-download-locked.sh`.
3. Commit as `fix(bootstrap): use global MSI cache with per-file download locks`.
