#!/usr/bin/env bash
# A cold launch proved the prefix empty three times, and each "empty" answer
# costs a paired probe with a 0.5 s pause: at the start of preparation, again
# for a stale session record, and again in the drain, although preparation
# normally starts no Wine. The start proof is reused while the engine's
# wineserver start log is unchanged; any server start, a missing log or a warm
# start keeps the full probe.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
prefix="$TMP/prefix"; mkdir -p "$prefix"
calls="$TMP/calls"; : >"$calls"
export CYDER_ENVIRONMENT_HELPER="$TMP/helper"
printf '#!/bin/bash\necho probe >>"%s"\necho "cyder-environment-v1 empty"\nexit 10\n' "$calls" >"$CYDER_ENVIRONMENT_HELPER"
chmod +x "$CYDER_ENVIRONMENT_HELPER"
source "$ROOT/scripts/cyder-common.sh" >/dev/null 2>&1
probes() { wc -l <"$calls" | tr -d ' '; }

export CYDER_LAUNCH_PREPARATION_PHASE=prepare
printf 'wineserver: diag start pid=1\nwineserver: atexit pid=1\n' >"$prefix/cyder-wineserver-diag.log"
cyder_launch_preparation_initial_state "$prefix" /bin/sh
assert_eq "$CYDER_LAUNCH_PREPARATION_INITIAL" idle "an empty reply starts preparation idle"
assert_eq "$(probes)" 1 "one probe for the initial state"
cyder_launch_preparation_drain "$prefix" /bin/sh
assert_eq "$(probes)" 1 "no Wine started during preparation: the drain reuses the start proof"
if ! cyder_launch_preparation_still_idle "$prefix"; then echo "FAIL unchanged log not idle" >&2; exit 1; fi

# A wineserver started during preparation (e.g. a registry write) appends to
# the log: the drain probes again.
printf 'wineserver: diag start pid=2\n' >>"$prefix/cyder-wineserver-diag.log"
if cyder_launch_preparation_still_idle "$prefix"; then echo "FAIL a server start kept the idle proof" >&2; exit 1; fi
cyder_launch_preparation_drain "$prefix" /bin/sh
assert_eq "$(probes)" 2 "a server start during preparation keeps the drain probe"

# No log (an engine without the start log) never counts as proof.
rm -f "$prefix/cyder-wineserver-diag.log"
cyder_launch_preparation_initial_state "$prefix" /bin/sh
cyder_launch_preparation_drain "$prefix" /bin/sh
assert_eq "$(probes)" 4 "without the start log the drain probes"

# Outside the prepare phase (final, CLI) the proof is never used.
printf 'wineserver: diag start pid=3\n' >"$prefix/cyder-wineserver-diag.log"
cyder_launch_preparation_initial_state "$prefix" /bin/sh
CYDER_LAUNCH_PREPARATION_PHASE=final
if cyder_launch_preparation_still_idle "$prefix"; then echo "FAIL proof used outside preparation" >&2; exit 1; fi
CYDER_LAUNCH_PREPARATION_PHASE=prepare

# A stale native session record: its calibration reuses the proof, unless
# another launch still holds a live reservation.
sessions="$(cyder_session_dir "$prefix")"; mkdir -p "$sessions"
printf 'pid=999999\nstate=background\nobserver=native\nmode=x\nsync=msync=0;esync=0;power=normal\n' >"$sessions/stale.session"
before="$(probes)"
cyder_session_acquire "$prefix" 0 0 normal /bin/sh
assert_eq "$(probes)" "$before" "a stale record is cleared with the start proof, no probe"
[[ ! -e "$sessions/stale.session" ]] || { echo "FAIL stale record kept" >&2; exit 1; }
[[ -n "${CYDER_SESSION_FILE:-}" ]] && rm -f "$CYDER_SESSION_FILE"

echo "PASS preparation reuses its empty proof while no wineserver has started"
