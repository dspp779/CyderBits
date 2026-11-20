#!/usr/bin/env bash
# Run the offline test suite (tests/test-*.sh, .py, .rb), one process per test.
#
#   bash tests/run.sh test-cyder-foo.sh  # one test (any word in the name works)
#   bash tests/run.sh --changed          # before a push: tests affected by work
#                                        # not yet pushed (upstream, else main)
#   bash tests/run.sh --changed REF      # ... against another base
#   bash tests/run.sh                    # everything (merges to main, releases)
#   bash tests/run.sh --list             # print the tests that would run
#   bash tests/run.sh --log-dir DIR      # keep per-test logs in DIR
#   bash tests/run.sh --timeout 300      # per-test limit in seconds (default 240;
#                                        # 600 with CYDER_TEST_FULL_TIMING=1)
#
# With --changed and a changed Swift file, the whole app is typechecked first
# (about 15 s). The runner prints the test count and an estimate from earlier
# runs. A test that exits 77 is skipped (it needs an idle desktop); skips do not
# fail the run unless CYDER_TEST_FULL_TIMING=1 (release runs), which also makes
# timing tests wait out the real limits. Exit status is 0 only when every
# selected test passes. See docs/development-testing.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIMIT=""
LOG_DIR=""
LIST=0
FILTERS=()
CHANGED_BASE=""
CHANGED_REQUESTED=0
DURATIONS="${CYDER_TEST_DURATIONS:-$ROOT/.tmp-tests/durations.tsv}"  # ignored (.tmp-*/)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1 ;;
    --timeout) LIMIT="${2:?--timeout needs seconds}"; shift ;;
    --log-dir) LOG_DIR="${2:?--log-dir needs a directory}"; shift ;;
    --changed)
      CHANGED_REQUESTED=1
      if [[ $# -gt 1 && "$2" != -* ]]; then CHANGED_BASE="$2"; shift; fi ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 64 ;;
    *) FILTERS+=("$1") ;;
  esac
  shift
done

# The slowest normal test takes about a minute; a hang should not cost 15.
if [[ -z "$LIMIT" ]]; then
  if [[ "${CYDER_TEST_FULL_TIMING:-}" == 1 ]]; then LIMIT=600; else LIMIT=240; fi
fi

CHANGED=()
if [[ "$CHANGED_REQUESTED" -eq 1 ]]; then
  if [[ -z "$CHANGED_BASE" ]]; then
    # Only what has not been pushed yet; a branch without upstream uses main.
    CHANGED_BASE="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || CHANGED_BASE=""
    [[ -n "$CHANGED_BASE" ]] || CHANGED_BASE=main
  fi
  echo "changes against $CHANGED_BASE"
  selection="$(python3 -I "$ROOT/tests/select-changed.py" --base "$CHANGED_BASE")" || exit 2
  swift_changed="$(python3 -I "$ROOT/tests/select-changed.py" --base "$CHANGED_BASE" --swift-changed 2>/dev/null)"
  if [[ "$swift_changed" == yes && "$LIST" -eq 0 ]]; then
    start=$SECONDS
    typecheck_log="${TMPDIR:-/tmp}/cyder-typecheck.$$.log"
    if bash "$ROOT/tests/lib/typecheck-app.sh" >"$typecheck_log" 2>&1; then
      echo "ok   app typecheck ($((SECONDS - start))s)"
    else
      echo "FAIL app typecheck ($((SECONDS - start))s) -> $typecheck_log"
      exit 1
    fi
  fi
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

cd "$ROOT"
tests=()
for path in tests/test-*; do
  case "$path" in *.sh|*.py|*.rb) ;; *) continue ;; esac
  selected "$(basename "$path")" && tests+=("$path")
done

if [[ "$LIST" -eq 1 ]]; then
  for path in ${tests[@]+"${tests[@]}"}; do basename "$path"; done
  exit 0
fi

# Estimate from earlier runs (unknown tests count 5 s).
estimate=0 known=0
for path in ${tests[@]+"${tests[@]}"}; do
  seconds="$(awk -F'\t' -v n="$(basename "$path")" '$1 == n { s = $2 } END { print s }' "$DURATIONS" 2>/dev/null)"
  if [[ -n "$seconds" ]]; then estimate=$((estimate + seconds)); known=$((known + 1)); else estimate=$((estimate + 5)); fi
done
echo "${#tests[@]} tests, about $((estimate / 60)) min $((estimate % 60)) s ($known timed before; limit ${LIMIT}s each)"

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

passed=0
failed=()
skipped=()
timings="$LOG_DIR/.durations.tsv"
: >"$timings"
for path in ${tests[@]+"${tests[@]}"}; do
  name="$(basename "$path")"
  case "$path" in
    *.sh) runner=bash ;;
    *.py) runner=python3 ;;
    *.rb) runner=ruby ;;
  esac
  start=$SECONDS
  # stdin is closed so a test that prompts fails instead of hanging the suite.
  if ${limit[@]+"${limit[@]}"} "$runner" "$path" >"$LOG_DIR/$name.log" 2>&1 </dev/null; then
    echo "ok   $name ($((SECONDS - start))s)"
    passed=$((passed + 1))
    printf '%s\t%s\n' "$name" "$((SECONDS - start))" >>"$timings"
  else
    status=$?
    if [[ $status -eq 77 && "${CYDER_TEST_FULL_TIMING:-}" != 1 ]]; then
      echo "skip $name ($(tail -1 "$LOG_DIR/$name.log"))"
      skipped+=("$name")
      continue
    fi
    [[ $status -eq 124 ]] && echo "     $name hit the ${LIMIT}s limit (--timeout to raise it)"
    echo "FAIL $name (exit $status, $((SECONDS - start))s) -> $LOG_DIR/$name.log"
    failed+=("$name")
  fi
done

# Remember how long passing tests took, for the next estimate.
if [[ -s "$timings" ]] && mkdir -p "$(dirname "$DURATIONS")"; then
  { [[ -f "$DURATIONS" ]] && cat "$DURATIONS"; cat "$timings"; } 2>/dev/null \
    | awk -F'\t' 'NF == 2 { s[$1] = $2 } END { for (n in s) print n "\t" s[n] }' | sort >"$DURATIONS.new" \
    && mv "$DURATIONS.new" "$DURATIONS"
fi

echo
echo "passed: $passed  failed: ${#failed[@]}  skipped: ${#skipped[@]}  logs: $LOG_DIR"
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "  skipped tests are not verified; run them alone when your change touches what they check"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
