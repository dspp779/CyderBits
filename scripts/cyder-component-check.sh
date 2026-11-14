#!/usr/bin/env bash
# Read-only evidence only: never repair, re-sign, delete or block a launch.
cyder_check_components() {
  local component="$1" depth="$2" resources budget rc
  local bottle="${3:-}"
  local -a bottle_args=()
  [[ -z "$bottle" ]] || bottle_args=(--bottle "$bottle")
  resources="${CYDER_RESOURCES:-${CYDER_APP:-}/Contents/Resources}"
  [[ -f "$resources/component-manifests/index.json" &&
     -f "$resources/ogom-scripts/cyder-component-integrity.rb" ]] || return 0
  budget=5
  [[ "$depth" == full ]] && budget=60
  rc=0
  # Any SDKROOT value stops the system Ruby's rbconfig from running xcrun at
  # start (0.3 s per call on every launch); the scan never compiles anything.
  SDKROOT="${SDKROOT:-}" /usr/bin/ruby "$resources/ogom-scripts/cyder-component-integrity.rb" check \
    --resources "$resources" --runtime "${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}" \
    --engine "${CYDER_ENGINES:-${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}/Engines}/${CYDER_ENGINE_NAME:-wine-x86_64}" \
    ${bottle_args[@]+"${bottle_args[@]}"} --component "$component" --depth "$depth" --budget "$budget" --summary >&2 || rc=$?
  [[ "$rc" == 0 ]] || echo "Component integrity $component/$depth: diagnostic exit $rc (no automatic repair)" >&2
  return 0
}

# A launch's preparation phase runs the quick check (about 3.5 s) alongside its
# own steps; the final phase of the same launch then skips it. Always wait
# before the phase ends so the scan never outlives its native executor.
cyder_check_components_start() {
  cyder_check_components "$@" &
  CYDER_COMPONENT_CHECK_PID=$!
}

cyder_check_components_wait() {
  [[ -n "${CYDER_COMPONENT_CHECK_PID:-}" ]] || return 0
  wait "$CYDER_COMPONENT_CHECK_PID" || true
  CYDER_COMPONENT_CHECK_PID=
}
