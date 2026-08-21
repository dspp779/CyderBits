#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

common_text="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common_text" "cyder_bootstrap_substage_begin" \
  "bootstrap timing helpers must exist in cyder-common.sh"
assert_contains "$common_text" "cyder_bootstrap_substage_end" \
  "bootstrap timing helpers must record substage duration"
assert_contains "$common_text" "bootstrap-timing.jsonl" \
  "bootstrap timing must persist to a jsonl log"

mono_text="$(cat "$ROOT/scripts/install-wine-mono.sh")"
gecko_text="$(cat "$ROOT/scripts/install-wine-gecko.sh")"
assert_contains "$mono_text" '--download-only' \
  "Wine Mono installer must support download-only prefetch"
assert_contains "$gecko_text" '--download-only' \
  "Wine Gecko installer must support download-only prefetch"

prefetch_text="$(cat "$ROOT/scripts/cyder-prefetch-bootstrap-msi.sh")"
assert_contains "$prefetch_text" "install-wine-mono.sh" \
  "prefetch script must download Wine Mono"
assert_contains "$prefetch_text" "install-wine-gecko.sh" \
  "prefetch script must download Wine Gecko"
assert_contains "$prefetch_text" "--download-only" \
  "prefetch script must use download-only mode"

provision_text="$(awk '
  /cyder_provision_prefix_baseline\(\)/ { found = 1 }
  found && /^cyder_prepare_pristine_template\(\)/ { exit }
  found { print }
' "$ROOT/scripts/cyder-common.sh")"
assert_contains "$provision_text" "cyder_bootstrap_substage_begin wineboot" \
  "provision must time wineboot"
assert_contains "$provision_text" "mono-download" \
  "provision must time Mono download separately from install"
assert_contains "$provision_text" "gecko-download" \
  "provision must time Gecko download separately from install"
assert_contains "$provision_text" "mono_dl_pid" \
  "Mono download must run in the background alongside wineboot"
assert_contains "$provision_text" "gecko_dl_pid" \
  "Gecko download must run in the background alongside wineboot"
assert_contains "$provision_text" "gfx_payload_pid" \
  "graphics payload unpack must run in the background alongside wineboot"
assert_contains "$provision_text" "graphics-payload" \
  "provision must time graphics payload unpack"
assert_contains "$provision_text" "graphics-winemetal" \
  "provision must time engine graphics link + winemetal after prefix exists"
# Downloads start before wineboot; wineboot must not wait for both to finish.
assert_contains "$provision_text" "cyder_init_bottle" \
  "provision must still wineboot the prefix"
# Ready-order install after wineboot (mutex scheduler).
assert_contains "$provision_text" "mono-install" \
  "provision must still install Mono after wineboot"
assert_contains "$provision_text" "gecko-install" \
  "provision must still install Gecko after wineboot"
assert_contains "$provision_text" "Bootstrap scheduler stalled" \
  "scheduler must fail closed if Mono/Gecko never become ready"
# msiexec hot path: install scripts without a fresh blocking --download-only
# between wineboot success and the install invocations.
wineboot_to_install="$(
  awk '
    /cyder_bootstrap_substage_end wineboot/ { found = 1 }
    found { print }
    /cyder_bootstrap_substage_begin mono-install|cyder_bootstrap_substage_begin gecko-install/ { exit }
  ' <<<"$provision_text"
)"
assert_not_contains "$wineboot_to_install" '--download-only' \
  "no blocking --download-only may sit on the wineboot→install hot path"

# P3: structured progress
assert_contains "$common_text" 'cyder_report_progress' \
  "progress helper must exist"
progress_helper="$(awk '
  /cyder_report_progress\(\)/ { found = 1 }
  found { print }
  found && /^}/ { exit }
' "$ROOT/scripts/cyder-common.sh")"
assert_contains "$progress_helper" "stage=" \
  "progress file must record stage= key"
assert_contains "$progress_helper" "label=" \
  "progress file must record label= key"
assert_contains "$progress_helper" "elapsed_ms=" \
  "progress file must record elapsed_ms= key"

# P4: idempotent skips
assert_contains "$provision_text" ".cyder-mono-" \
  "Mono install must skip when .cyder-mono marker exists"
assert_contains "$provision_text" ".cyder-gecko-" \
  "Gecko install must skip when .cyder-gecko marker exists"
assert_contains "$provision_text" "syswow64/tar.exe" \
  "tar setup must skip when tar.exe already exists"
assert_contains "$provision_text" "略過" \
  "skipped components must report a skip progress message"

# P5: shared bootstrap graphics only after prefix exists
bootstrap_shared="$(awk '
  /cyder_bootstrap_shared_prefix\(\)/ { found = 1 }
  found { print }
  found && /^cyder_swift_bin\(\)/ { exit }
' "$ROOT/scripts/cyder-common.sh")"
assert_not_contains "$(echo "$bootstrap_shared" | head -n 25)" "cyder_prepare_graphics_prefix" \
  "shared bootstrap must not prepare graphics before the prefix exists"
assert_contains "$bootstrap_shared" "cyder_ensure_graphics" \
  "shared bootstrap must ensure graphics after the prefix is provisioned"

measure_text="$(cat "$ROOT/scripts/cyder-measure-startup.sh")"
assert_contains "$measure_text" "bootstrap-timing.jsonl" \
  "measure script must summarize bootstrap substage timing"

# Exercise timing helpers without Wine.
# shellcheck source=cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"
CYDER_SUPPORT="$TMP/support"
CYDER_DIAGNOSTIC_VERBOSE=1
CYDER_DIAGNOSTIC_SESSION_ID="timing-test"
mkdir -p "$CYDER_SUPPORT/Logs"
CYDER_BOOTSTRAP_STAGE_STACK=()
CYDER_BOOTSTRAP_T0_STACK=()

set +e
timing_out="$(
  cyder_bootstrap_substage_begin wineboot
  cyder_bootstrap_substage_begin wineboot-artifact-wait
  cyder_bootstrap_substage_end wineboot-artifact-wait 0
  cyder_bootstrap_substage_end wineboot 0 2>&1
)"
timing_status=$?
set -e
assert_eq "$timing_status" "0" "bootstrap substage timing helpers should succeed"

CYDER_PROGRESS_FILE="$TMP/progress.txt"
cyder_report_progress "正在安裝 .NET（Wine Mono）…" "mono-install" "4820"
progress_out="$(cat "$CYDER_PROGRESS_FILE")"
assert_contains "$progress_out" "stage=mono-install" \
  "progress file must include the active stage"
assert_contains "$progress_out" "label=正在安裝 .NET（Wine Mono）…" \
  "progress file must include the user-facing label"
assert_contains "$progress_out" "elapsed_ms=4820" \
  "progress file must include elapsed_ms"
unset CYDER_PROGRESS_FILE

timing_file="$CYDER_SUPPORT/Logs/bootstrap-timing.jsonl"
assert test -f "$timing_file"
assert_contains "$(cat "$timing_file")" '"stage":"wineboot-artifact-wait"' \
  "timing log must record nested artifact wait"
assert_contains "$(cat "$timing_file")" '"stage":"wineboot"' \
  "timing log must record wineboot"
assert_contains "$timing_out" "event=bootstrap-substage" \
  "verbose diagnostics must emit bootstrap-substage events"
assert_contains "$timing_out" "elapsed_ms=" \
  "bootstrap substage diagnostics must include elapsed_ms"

wineboot_text="$(awk '
  /cyder_init_bottle\(\)/ { found = 1 }
  found && /^cyder_health_check_prefix\(\)/ { exit }
  found { print }
' "$ROOT/scripts/cyder-common.sh")"
assert_contains "$wineboot_text" "duration_ms=" \
  "wineboot operation log must record total duration"
assert_contains "$wineboot_text" "cyder_bootstrap_substage_begin wineboot-artifact-wait" \
  "wineboot must time artifact readiness wait separately"
assert_contains "$wineboot_text" "success_wait=artifact-ready" \
  "wineboot success path must wait for artifacts without stopping wineserver"
assert_not_contains "$wineboot_text" 'wineserver" -p' \
  "wineboot must not force wineserver -p; keep alive by chaining MSI installs"
assert_not_contains "$wineboot_text" "wineserver_persist=" \
  "wineboot must not log wineserver -p persistence"
assert_not_contains "$wineboot_text" "success_wait=wineserver -w" \
  "wineboot success path must not wait for wineserver exit"
# Success path must not issue wineserver -k; only failure_cleanup may.
assert_contains "$wineboot_text" "failure_cleanup=wineserver -k" \
  "wineboot failure path must still clean up wineserver"
success_k_hits="$(
  awk '
    /success_wait=artifact-ready/ { in_success = 1 }
    in_success && /failure_cleanup=wineserver -k/ { in_success = 0 }
    in_success && /wineserver.*-k/ { print }
  ' <<<"$wineboot_text"
)"
assert_eq "$success_k_hits" "" \
  "wineboot success path must keep wineserver alive for Mono/Gecko"

echo "PASS test-cyder-bootstrap-timing"
