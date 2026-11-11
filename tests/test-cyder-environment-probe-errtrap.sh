#!/usr/bin/env bash
# The environment helper answers "empty" with exit 10. Under the launcher's
# errtrace ERR trap that answer must not be logged as an error.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
errors="$TMP/errors"
: >"$errors"
trap 'echo "ERR line=$LINENO" >>"$errors"' ERR
export CYDER_ENVIRONMENT_HELPER="$TMP/helper"
printf '#!/bin/bash\necho "cyder-environment-v1 empty"\nexit 10\n' >"$CYDER_ENVIRONMENT_HELPER"
chmod +x "$CYDER_ENVIRONMENT_HELPER"
source "$ROOT/scripts/cyder-common.sh" >/dev/null 2>&1
cyder_prefix_has_live_session_pids() { return 1; }
cyder_launch_preparation_initial_state "$TMP" /bin/sh
[[ "$CYDER_LAUNCH_PREPARATION_INITIAL" == idle ]] || { echo "FAIL empty reply not read as idle" >&2; exit 1; }
if cyder_session_environment_live "$TMP" /bin/sh; then echo "FAIL empty reply read as live" >&2; exit 1; fi
[[ ! -s "$errors" ]] || { echo "FAIL ERR trap fired: $(cat "$errors")" >&2; exit 1; }
echo "PASS environment-state replies do not trip the ERR trap"
