# First-open → Preferences Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Phase A dry-run script that mirrors `ensureEnvironment` (including prefetch∥bootstrap overlap), emit `spans.jsonl` / `results.json` / Mermaid `timeline.md`, and run one isolated measurement.

**Architecture:** Independent bash+python harness under `scripts/` uses a clean `CYDER_SUPPORT`, records monotonic `start_ms`/`end_ms` for each span, starts MSI prefetch in the background then runs `--bootstrap-only`, merges `bootstrap-timing.jsonl` onto the same axis, and writes a Mermaid gantt. Phase B App instrumentation is out of scope for this plan.

**Tech Stack:** bash, python3, existing `dist/Cyder.app` launcher scripts, Mermaid gantt markdown.

## Global Constraints

- Do not mutate live `~/Library/Application Support/Cyder`.
- Do not change product launch / Preferences behavior.
- Do not rebuild/repack engine unless artifacts are missing.
- Prefer independent script `scripts/cyder-measure-first-open-preferences.sh` (do not break `cyder-measure-startup.sh` subsequent-open stats).
- `T_settings` / `settings-ready` is environment-ready proxy, not NSWindow didAppear.
- Phase B optional and not required for this plan's acceptance.

---

### Task 1: Measure script with overlap-aware spans

**Files:**
- Create: `scripts/cyder-measure-first-open-preferences.sh`
- Create: `tests/test-cyder-measure-first-open-preferences.sh` (smoke: help / missing app fails cleanly; optional dry logic unit via python helper if extracted)

**Interfaces:**
- Consumes: `CYDER_APP` (default `dist/Cyder.app`), bundled `engine-*.tar.*`, `ogom-scripts/cyder_launcher.sh`, `ogom-scripts/cyder-prefetch-bootstrap-msi.sh`
- Produces: `$OUT/spans.jsonl`, `$OUT/results.json`, `$OUT/timeline.md`, `$OUT/first-support/` (isolated support), per-span logs

- [ ] **Step 1: Write the measure script**

Script outline (must match App order):

1. Resolve `APP`, `LAUNCHER`, `ENGINE_SRC`, `OUT=debug/cyder-first-open-prefs-$(date …)`.
2. `mkdir -p "$OUT/first-support"`; `export CYDER_SUPPORT=…`; `export CYDER_DIAGNOSTIC_VERBOSE=1`.
3. Python (or bash+python) helpers:
   - `T0 = time.perf_counter()`
   - `emit_span(name, start_ms, end_ms, status, parent=None)` → append JSONL
   - `run_span(name, cmd…)` → serial timed subprocess
4. Serial: `ensure-engine-only`, then `ensure-graphics-only`.
5. Overlap:
   - Record `prefetch_start`; start `bash cyder-prefetch-bootstrap-msi.sh` in background (capture PID, redirect log).
   - Immediately `run_span bootstrap-only` with `--bootstrap-only`.
   - `wait` prefetch PID; emit `prefetch-msi` span with true end.
6. Parse bootstrap stdout/machine result for `healthChecked=1`; if missing, `run_span health-check`.
7. Emit zero-duration (or instantaneous) `settings-ready` at current elapsed.
8. Merge `$CYDER_SUPPORT/Logs/bootstrap-timing.jsonl` into spans with `parent=bootstrap-only`, offset by bootstrap `start_ms` if substage times are relative; if substages only have `elapsed_ms` without absolute start, place them sequentially under bootstrap using recorded order / cumulative if the jsonl includes wall timestamps — otherwise attach as duration-only annotations in `results.json` and still list them in gantt as sequential children starting at bootstrap start when only elapsed is known.
9. Write `timeline.md` Mermaid gantt from spans; write `results.json` with `settings_ready_ms`, overlap boolean, span list.

Key python snippet for overlap start:

```python
prefetch_start = (time.perf_counter() - t0) * 1000
proc = subprocess.Popen(["bash", prefetch_script], env=env, stdout=log, stderr=subprocess.STDOUT)
bootstrap_start = (time.perf_counter() - t0) * 1000
# run bootstrap to completion…
bootstrap_end = …
proc.wait()
prefetch_end = (time.perf_counter() - t0) * 1000
emit("prefetch-msi", prefetch_start, prefetch_end, proc.returncode)
emit("bootstrap-only", bootstrap_start, bootstrap_end, bootstrap_rc)
```

- [ ] **Step 2: Smoke test for script presence and usage**

```bash
# tests/test-cyder-measure-first-open-preferences.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/cyder-measure-first-open-preferences.sh" --help | grep -q first-open
# Missing app should exit non-zero without touching live support
CYDER_APP="$ROOT/dist/Cyder.app.missing" \
  bash "$ROOT/scripts/cyder-measure-first-open-preferences.sh" && exit 1 || true
echo OK
```

- [ ] **Step 3: Run smoke test**

Run: `bash tests/test-cyder-measure-first-open-preferences.sh`  
Expected: prints `OK`

- [ ] **Step 4: Commit** (only if user asks)

Do not commit unless explicitly requested.

---

### Task 2: Run isolated dry-run and publish timeline

**Files:**
- Create (runtime): `debug/cyder-first-open-prefs-<ts>/spans.jsonl`
- Create (runtime): `debug/cyder-first-open-prefs-<ts>/results.json`
- Create (runtime): `debug/cyder-first-open-prefs-<ts>/timeline.md`
- Optional: update or create canvas under Cursor canvases from results (not required if markdown gantt is clear)

**Interfaces:**
- Consumes: Task 1 script
- Produces: measured wall-clock to `settings-ready`, overlap evidence, user-facing timeline

- [ ] **Step 1: Run full dry-run**

```bash
bash scripts/cyder-measure-first-open-preferences.sh
```

Expected: exit 0; `settings-ready` span present; prefetch and bootstrap intervals overlap when network/cache allows (document if prefetch finished before bootstrap started — still valid).

- [ ] **Step 2: Verify acceptance checks**

```bash
OUT=$(ls -td debug/cyder-first-open-prefs-* | head -1)
python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
spans = [json.loads(l) for l in (out/"spans.jsonl").read_text().splitlines() if l.strip()]
names = {s["name"] for s in spans}
assert "ensure-engine-only" in names
assert "bootstrap-only" in names
assert "prefetch-msi" in names
assert "settings-ready" in names
by = {s["name"]: s for s in spans if s["name"] in ("prefetch-msi","bootstrap-only")}
p, b = by["prefetch-msi"], by["bootstrap-only"]
overlap = p["start_ms"] < b["end_ms"] and b["start_ms"] < p["end_ms"]
print("settings_ready_ms", max(s["end_ms"] for s in spans if s["name"]=="settings-ready"))
print("prefetch_bootstrap_overlap", overlap)
print("timeline_exists", (out/"timeline.md").exists())
PY
```

- [ ] **Step 3: Summarize for user in Traditional Chinese**

Include: total to settings-ready, top spans, whether prefetch overlapped bootstrap, path to `timeline.md`, note Phase B not run.

---

## Plan self-review

1. Spec coverage: Phase A spans, overlap, isolated support, outputs, no live bottle, Phase B deferred — covered. Canvas optional — optional in Task 2.
2. Placeholders: none.
3. Naming: `prefetch-msi`, `bootstrap-only`, `settings-ready` match spec.
