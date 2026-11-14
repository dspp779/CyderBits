#!/usr/bin/env bash
# xctrace-frames.py: present gaps and per-thread samples from small exports
# shaped like real `xctrace export` output (ids, refs, nanosecond times).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PY="$ROOT/.agents/skills/wine-game-compat-testing/scripts/xctrace-frames.py"

cat >"$TMP/toc.xml" <<'EOF'
<trace-toc><run number="1"><info><summary><start-date>2026-11-13T15:33:21.293+08:00</start-date></summary></info></run></trace-toc>
EOF

# Presents of pid 100 at 0, 16, 32 ms, then a 1000 ms stall, then 1048 ms.
# One present of another pid sits inside the stall and must be ignored.
{
  echo '<trace-query-result><node>'
  echo '<row><start-time id="1">0</start-time><thread id="2" fmt="wine (0x1) (wine, pid: 100)"/></row>'
  echo '<row><start-time id="3">16000000</start-time><thread ref="2"/></row>'
  echo '<row><start-time id="4">32000000</start-time><thread ref="2"/></row>'
  echo '<row><start-time id="5">500000000</start-time><thread id="6" fmt="other (0x9) (other, pid: 200)"/></row>'
  echo '<row><start-time id="7">1032000000</start-time><thread ref="2"/></row>'
  echo '<row><start-time id="8">1048000000</start-time><thread ref="2"/></row>'
  echo '</node></trace-query-result>'
} >"$TMP/presents.xml"

# Profile: main thread 0x1 with two samples inside ntdll (0x2000-0x3000) and
# one in game code; a second thread 0x2 with one sample.
{
  echo '<trace-query-result><node>'
  echo '<row><sample-time id="1">100000000</sample-time><thread id="2" fmt="wine (0x1) (wine, pid: 100)"/><tagged-backtrace id="3"><frame id="4" addr="0x7ff800000010"/><frame id="5" addr="0x2010"/></tagged-backtrace></row>'
  echo '<row><sample-time id="6">101000000</sample-time><thread ref="2"/><tagged-backtrace ref="3"/></row>'
  echo '<row><sample-time id="7">102000000</sample-time><thread ref="2"/><tagged-backtrace id="8"><frame id="9" addr="0x9000"/></tagged-backtrace></row>'
  echo '<row><sample-time id="10">103000000</sample-time><thread id="11" fmt="dxvk-submit (0x2) (wine, pid: 100)"/><tagged-backtrace ref="8"/></row>'
  echo '<row><sample-time id="12">900000000</sample-time><thread ref="2"/><tagged-backtrace ref="3"/></row>'
  echo '</node></trace-query-result>'
} >"$TMP/profile.xml"

t0="$(python3 -I "$PY" start "$TMP/toc.xml")"
assert_eq "$t0" "1794555201.293" "trace start converts the TOC date to epoch"

gaps="$(python3 -I "$PY" gaps "$TMP/presents.xml" 100 "$t0" 1)"
assert_contains "$gaps" "presents=5 " "only the game's presents are counted"
assert_contains "$gaps" "gap 1000 ms from 1794555201.325" "the stall is the longest gap"

bins="$(python3 -I "$PY" bins "$TMP/presents.xml" 100 "$t0" 1794555201.293 1794555202.493)"
assert_eq "$bins" "1794555201.3:3 1794555201.5:0 1794555201.7:0 1794555201.9:0 1794555202.1:0 1794555202.3:2" "presents per 200 ms"

threads="$(python3 -I "$PY" threads "$TMP/profile.xml" 100 "$t0" 1794555201.3 1794555201.5)"
assert_contains "$threads" "samples=4" "samples inside the window only"
assert_contains "$threads" "     3  wine (0x1)" "main thread has three samples"

where="$(python3 -I "$PY" where "$TMP/profile.xml" 100 "$t0" 1794555201.3 1794555201.5 0x1 2000-3000 7ff800000000-7ff900000000)"
assert_contains "$where" "thread 0x1: 3 on-CPU samples" "thread filter"
assert_contains "$where" "     2  stack touches 2000-3000" "range hits counted per sample"
assert_contains "$where" "     2  stack touches 7ff800000000-7ff900000000" "leaf range counted"

if python3 -I "$PY" start /dev/null >/dev/null 2>&1; then
  echo "ASSERT failed: an empty TOC must fail" >&2; exit 1
fi

echo "ok: xctrace-frames"
