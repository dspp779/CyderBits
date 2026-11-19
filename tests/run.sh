#!/usr/bin/env bash
# Run the offline test suite (tests/test-*.sh, .py, .rb), one process per test.
#
#   bash tests/run.sh                    # everything
#   bash tests/run.sh graphics dxmt      # only tests whose name contains a word
#   bash tests/run.sh --changed          # tests affected by changes against main
#   bash tests/run.sh --changed REF      # ... against another base
#   bash tests/run.sh --list             # print the tests that would run
#   bash tests/run.sh --log-dir DIR      # keep per-test logs in DIR
#   bash tests/run.sh --timeout 300      # per-test limit in seconds (default 900)
#
# A test that exits 77 is skipped (it needs an idle desktop); skips do not fail
# the run unless CYDER_TEST_FULL_TIMING=1 (release runs), which also makes
# timing tests wait out the real limits. Exit status is 0 only when every
# selected test passes. See docs/development-testing.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIMIT=900
LOG_DIR=""
LIST=0
FILTERS=()
CHANGED_BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1 ;;
    --timeout) LIMIT="${2:?--timeout needs seconds}"; shift ;;
    --log-dir) LOG_DIR="${2:?--log-dir needs a directory}"; shift ;;
    --changed)
      CHANGED_BASE=main
      if [[ $# -gt 1 && "$2" != -* ]]; then CHANGED_BASE="$2"; shift; fi ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 64 ;;
    *) FILTERS+=("$1") ;;
  esac
  shift
done

CHANGED=()
if [[ -n "$CHANGED_BASE" ]]; then
  selection="$(python3 -I "$ROOT/tests/select-changed.py" --base "$CHANGED_BASE")" || exit 2
  if [[ "$selection" != ALL ]]; then
    while IFS= read -r name; do [[ -n "$name" ]] && CHANGED+=("$name"); done <<<"$selection"
    if [[ ${#CHANGED[@]} -eq 0 ]]; then echo "no tests affected"; exit 0; fi
  fi
fi

selected() {
  local name="$1" filter
  if [[ ${#CHANGED[@]} -gt 0 ]]; then
    local wanted found=1
    for wanted in "${CHANGED[@]}"; do [[ "$name" == "$wanted" ]] && found=0; done
    [[ $found -eq 0 ]] || return 1
  fi
  [[ ${#FILTERS[@]} -eq 0 ]] && return 0
  for filter in "${FILTERS[@]}"; do
    [[ "$name" == *"$filter"* ]] && return 0
  done
  return 1
}

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-tests.XXXXXX")"
fi
mkdir -p "$LOG_DIR"

limit=()
if command -v timeout >/dev/null 2>&1; then
  limit=(timeout "$LIMIT")
fi

# One Swift module cache for the whole run (see tests/lib/swiftc).
export CYDER_TEST_MODULE_CACHE="$LOG_DIR/.module-cache"
export PATH="$ROOT/tests/lib:$PATH"

cd "$ROOT"
passed=0
failed=()
skipped=()
for path in tests/test-*; do
  name="$(basename "$path")"
  case "$path" in
    *.sh) runner=bash ;;
    *.py) runner=python3 ;;
    *.rb) runner=ruby ;;
    *) continue ;;
  esac
  selected "$name" || continue
  if [[ "$LIST" -eq 1 ]]; then
    echo "$name"
    continue
  fi
  start=$SECONDS
  # stdin is closed so a test that prompts fails instead of hanging the suite.
  if ${limit[@]+"${limit[@]}"} "$runner" "$path" >"$LOG_DIR/$name.log" 2>&1 </dev/null; then
    echo "ok   $name ($((SECONDS - start))s)"
    passed=$((passed + 1))
  else
    status=$?
    if [[ $status -eq 77 && "${CYDER_TEST_FULL_TIMING:-}" != 1 ]]; then
      echo "skip $name ($(tail -1 "$LOG_DIR/$name.log"))"
      skipped+=("$name")
      continue
    fi
    echo "FAIL $name (exit $status, $((SECONDS - start))s) -> $LOG_DIR/$name.log"
    failed+=("$name")
  fi
done

[[ "$LIST" -eq 1 ]] && exit 0

echo
echo "passed: $passed  failed: ${#failed[@]}  skipped: ${#skipped[@]}  logs: $LOG_DIR"
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
