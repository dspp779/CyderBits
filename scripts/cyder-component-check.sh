#!/usr/bin/env bash
# Read-only evidence only: never repair, re-sign, delete or block a launch.
cyder_check_components() {
  local component="$1" depth="$2" resources budget rc
  resources="${CYDER_RESOURCES:-${CYDER_APP:-}/Contents/Resources}"
  [[ -f "$resources/component-manifests/index.json" &&
     -f "$resources/ogom-scripts/cyder-component-integrity.rb" ]] || return 0
  budget=5
  [[ "$depth" == full ]] && budget=60
  rc=0
  /usr/bin/ruby "$resources/ogom-scripts/cyder-component-integrity.rb" check \
    --resources "$resources" --runtime "${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}" \
    --engine "${CYDER_ENGINES:-${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}/Engines}/${CYDER_ENGINE_NAME:-wine-x86_64}" \
    --component "$component" --depth "$depth" --budget "$budget" --summary >&2 || rc=$?
  [[ "$rc" == 0 ]] || echo "Component integrity $component/$depth: diagnostic exit $rc (no automatic repair)" >&2
  return 0
}
