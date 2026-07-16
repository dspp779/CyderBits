#!/usr/bin/env bash
# Cyder launcher — open Windows EXE with shared prefix (no Python).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$SCRIPT_DIR/cyder-common.sh"

if cyder_resources_has_bundled_engine "$(dirname "$SCRIPT_DIR")"; then
  cyder_init_paths "$(dirname "$SCRIPT_DIR")"
else
  cyder_init_paths "$SCRIPT_DIR"
fi
cyder_load_saved_settings

CYDER_DIAGNOSTIC_STAGE="${CYDER_DIAGNOSTIC_STAGE:-launcher-start}"
CYDER_DIAGNOSTIC_LAST_ERROR=""
CYDER_DIAGNOSTIC_EXPECTED_EXIT="0"

cyder_set_stage() {
  CYDER_DIAGNOSTIC_STAGE="$1"
  export CYDER_DIAGNOSTIC_STAGE
  if [[ -n "${CYDER_DIAGNOSTIC_SESSION_ID:-}" || "${CYDER_DIAGNOSTIC_VERBOSE:-0}" == 1 ]]; then
    printf 'diagnostic event=stage session=%s stage=%s\n' \
      "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "$CYDER_DIAGNOSTIC_STAGE" >&2
  fi
}

cyder_on_error() {
  local status="$1" line="$2" command="$3"
  CYDER_DIAGNOSTIC_LAST_ERROR="status=$status line=$line command=$command"
  printf 'diagnostic event=error session=%s stage=%s status=%s line=%s command=%q\n' \
    "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "$CYDER_DIAGNOSTIC_STAGE" \
    "$status" "$line" "$command" >&2
  return "$status"
}

cyder_on_exit() {
  local status="$?"
  if [[ "$status" -ne 0 && "$status" -ne "${CYDER_DIAGNOSTIC_EXPECTED_EXIT:-0}" ]]; then
    printf 'diagnostic event=exit session=%s stage=%s status=%s detail=%q\n' \
      "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "$CYDER_DIAGNOSTIC_STAGE" \
      "$status" "${CYDER_DIAGNOSTIC_LAST_ERROR:-explicit-exit}" >&2
  fi
}

trap 'cyder_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cyder_on_exit EXIT
cyder_set_stage launcher-start

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [game.exe ...]

Options:
  --engine-src PATH   Wine engine source (default: install/wine-cx26-x86_64 or app payload)
  --dry-run           Print paths without installing engine or launching
  --bootstrap-only    Bootstrap shared prefix (mono, tar, hi-res) and exit
  --health-check      Validate the Wine engine and run a minimal prefix probe
  --rebuild-prefix    Rebuild the shared Windows game environment safely
  --ensure-engine-only  Install shared engine from payload/tarball and exit
  --ensure-rosetta-only Check Rosetta 2 on Apple Silicon and exit
  --stop-all          Stop all EXEs in the Cyder shared prefix and exit
  --has-running-exes  Exit 0 if the shared prefix has running EXEs, otherwise 1
  --apply-settings-only Apply saved settings without installing the environment
  --apply-settings-prefix PREFIX Apply saved settings to an existing bottle
  --session-acquire PREFIX OWNER_PID MSYNC ESYNC POWER Reserve a bottle session
  --session-update PREFIX SESSION_FILE NEW_PID Update a reserved session PID
  --session-release PREFIX SESSION_FILE Release a reserved session
  --templates-ready  Check pristine/golden template compatibility
  --launch-exe PATH   Launch .exe (engine + bootstrap must already be ready)
  --profile-resolve PATH  Resolve PATH to its per-game bottle and exit
  --profile-create PATH [pristine|golden]  Create/resolve a per-game bottle and exit
  --profile-remove PATH  Remove a per-game bottle/profile and exit
  -h, --help          Show this help
EOF
}

DRY_RUN=0
BOOTSTRAP_ONLY=0
HEALTH_CHECK=0
REBUILD_PREFIX=0
ENSURE_ENGINE_ONLY=0
ENSURE_ROSETTA_ONLY=0
STOP_ALL=0
HAS_RUNNING_EXES=0
APPLY_SETTINGS_ONLY=0
LAUNCH_ONLY=0
PROFILE_ACTION=""
PROFILE_EXE=""
PROFILE_TEMPLATE="golden"
APPLY_SETTINGS_PREFIX=""
APPLY_SETTINGS_PREFIX_SET=0
SESSION_ACTION=""
SESSION_ARGS=()
TEMPLATES_READY=0
ENGINE_SRC="$CYDER_ENGINE_SRC"
EXE_ARGS=()
POSITIONAL_EXE=0

cyder_write_machine_result() {
  local key="$1" value="$2" result_file="${CYDER_RESULT_FILE:-}"
  [[ -n "$result_file" ]] || return 0
  local result_dir tmp
  result_dir="$(dirname "$result_file")"
  mkdir -p "$result_dir"
  tmp="${result_file}.tmp.$$"
  rm -f "$tmp"
  /usr/bin/plutil -create xml1 "$tmp"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$tmp"
  /usr/bin/plutil -insert "$key" -string "$value" "$tmp"
  mv -f "$tmp" "$result_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --bootstrap-only)
      BOOTSTRAP_ONLY=1
      shift
      ;;
    --health-check)
      HEALTH_CHECK=1
      shift
      ;;
    --rebuild-prefix)
      REBUILD_PREFIX=1
      shift
      ;;
    --ensure-engine-only)
      ENSURE_ENGINE_ONLY=1
      shift
      ;;
    --ensure-rosetta-only)
      ENSURE_ROSETTA_ONLY=1
      shift
      ;;
    --stop-all)
      STOP_ALL=1
      shift
      ;;
    --has-running-exes)
      HAS_RUNNING_EXES=1
      shift
      ;;
    --apply-settings-only)
      APPLY_SETTINGS_ONLY=1
      shift
      ;;
    --apply-settings-prefix)
      [[ $# -ge 2 ]] || { echo "--apply-settings-prefix requires PREFIX" >&2; exit 1; }
      APPLY_SETTINGS_PREFIX="$2"
      APPLY_SETTINGS_PREFIX_SET=1
      shift 2
      ;;
    --session-acquire | --session-update | --session-release)
      [[ -z "$SESSION_ACTION" ]] || { echo "session action specified more than once" >&2; exit 1; }
      SESSION_ACTION="${1#--session-}"
      needed=6
      [[ "$SESSION_ACTION" == update ]] && needed=4
      [[ "$SESSION_ACTION" == release ]] && needed=3
      [[ $# -ge "$needed" ]] || { echo "--session-$SESSION_ACTION has missing arguments" >&2; exit 1; }
      SESSION_ARGS=("${@:2:$((needed - 1))}")
      shift "$needed"
      ;;
    --templates-ready)
      TEMPLATES_READY=1
      shift
      ;;
    --launch-exe)
      [[ $# -ge 2 ]] || {
        echo "--launch-exe requires PATH" >&2
        exit 1
      }
      LAUNCH_ONLY=1
      EXE_ARGS+=("$2")
      shift 2
      ;;
    --profile-resolve)
      [[ $# -ge 2 ]] || { echo "--profile-resolve requires PATH" >&2; exit 1; }
      [[ -z "$PROFILE_ACTION" ]] || { echo "profile action specified more than once" >&2; exit 1; }
      PROFILE_ACTION=resolve
      PROFILE_EXE="$2"
      shift 2
      ;;
    --profile-create)
      [[ $# -ge 2 ]] || { echo "--profile-create requires PATH" >&2; exit 1; }
      [[ -z "$PROFILE_ACTION" ]] || { echo "profile action specified more than once" >&2; exit 1; }
      PROFILE_ACTION=create
      PROFILE_EXE="$2"
      if [[ $# -ge 3 && ( "$3" == pristine || "$3" == golden ) ]]; then
        PROFILE_TEMPLATE="$3"
        shift 3
      else
        shift 2
      fi
      ;;
    --profile-remove)
      [[ $# -ge 2 ]] || { echo "--profile-remove requires PATH" >&2; exit 1; }
      [[ -z "$PROFILE_ACTION" ]] || { echo "profile action specified more than once" >&2; exit 1; }
      PROFILE_ACTION=remove
      PROFILE_EXE="$2"
      shift 2
      ;;
    --engine-src)
      [[ $# -ge 2 ]] || {
        echo "--engine-src requires PATH" >&2
        exit 1
      }
      ENGINE_SRC="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      EXE_ARGS+=("$@")
      [[ $# -gt 0 ]] && POSITIONAL_EXE=1
      break
      ;;
    -*)
      if [[ "$1" == -psn_* ]]; then
        shift
        continue
      fi
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      EXE_ARGS+=("$1")
      POSITIONAL_EXE=1
      shift
      ;;
  esac
done

primary_actions=0
[[ -n "$PROFILE_ACTION" ]] && primary_actions=$((primary_actions + 1))
[[ -n "$SESSION_ACTION" ]] && primary_actions=$((primary_actions + 1))
[[ "$APPLY_SETTINGS_PREFIX_SET" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$APPLY_SETTINGS_ONLY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$LAUNCH_ONLY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$STOP_ALL" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$HAS_RUNNING_EXES" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$TEMPLATES_READY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$BOOTSTRAP_ONLY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$HEALTH_CHECK" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$REBUILD_PREFIX" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$ENSURE_ENGINE_ONLY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$ENSURE_ROSETTA_ONLY" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$DRY_RUN" -eq 1 ]] && primary_actions=$((primary_actions + 1))
[[ "$POSITIONAL_EXE" -eq 1 && "$DRY_RUN" -eq 0 && "$LAUNCH_ONLY" -eq 0 ]] && primary_actions=$((primary_actions + 1))
(( primary_actions <= 1 )) || { echo "Only one profile/session/settings action may be specified" >&2; exit 1; }

if [[ -n "$PROFILE_ACTION" ]]; then
  cyder_set_stage profile-"$PROFILE_ACTION"
  [[ -f "$PROFILE_EXE" ]] || { echo "Profile EXE does not exist: $PROFILE_EXE" >&2; exit 1; }
  profile_script="$CYDER_SCRIPTS/cyder-profile.sh"
  [[ -x "$profile_script" ]] || { echo "Profile backend is unavailable: $profile_script" >&2; exit 1; }
  if [[ "$PROFILE_ACTION" == resolve ]]; then
    bash "$profile_script" resolve "$PROFILE_EXE" "$CYDER_SUPPORT"
  elif [[ "$PROFILE_ACTION" == remove ]]; then
    cyder_profile_backend_load
    profile_id="$(bash "$profile_script" id "$PROFILE_EXE")"
    profile_bottle="$CYDER_SUPPORT/bottles/$profile_id"
    if cyder_has_running_prefix "$profile_bottle" || cyder_profile_has_live_sessions "$profile_bottle"; then
      echo "Cannot remove a per-game bottle while it is running: $profile_bottle" >&2
      exit 75
    fi
    bash "$profile_script" remove "$PROFILE_EXE" "$CYDER_SUPPORT"
  else
    template_dir="$CYDER_SUPPORT/templates/$PROFILE_TEMPLATE"
    [[ -d "$template_dir" && -f "$template_dir/manifest.json" ]] || {
      echo "Profile template is not ready: $template_dir (manifest.json required)" >&2
      exit 2
    }
    profile_wine="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
    [[ -x "$profile_wine" ]] || {
      echo "Profile creation requires an installed Wine engine: $profile_wine" >&2
      exit 2
    }
    profile_engine_version="$(cyder_template_engine_version "$profile_wine")"
    [[ -n "$profile_engine_version" && "$profile_engine_version" != unknown ]] || {
      echo "Profile creation requires a detectable Wine engine version" >&2
      exit 2
    }
    profile_revision="${CYDER_TEMPLATE_REVISION:-1}"
    [[ "$profile_revision" =~ ^[1-9][0-9]*$ ]] || {
      echo "Invalid CYDER_TEMPLATE_REVISION: $profile_revision" >&2
      exit 2
    }
    if ! bash "$profile_script" template-ready "$PROFILE_TEMPLATE" "$CYDER_SUPPORT" \
        "$profile_revision" "$profile_engine_version" >/dev/null; then
      echo "Profile template is not ready for revision $profile_revision and engine $profile_engine_version" >&2
      exit 2
    fi
    bash "$profile_script" create "$PROFILE_EXE" "$template_dir" "$CYDER_SUPPORT"
  fi
  exit $?
fi

if [[ "$TEMPLATES_READY" -eq 1 ]]; then
  CYDER_DIAGNOSTIC_EXPECTED_EXIT=1
  profile_script="$CYDER_SCRIPTS/cyder-profile.sh"
  engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
  revision="${CYDER_TEMPLATE_REVISION:-1}"
  if [[ ! -x "$profile_script" || ! -x "$engine" || ! "$revision" =~ ^[1-9][0-9]*$ ]]; then
    exit 1
  fi
  engine_version="$(cyder_template_engine_version "$engine")"
  [[ -n "$engine_version" && "$engine_version" != unknown ]] || exit 1
  for template_name in pristine golden; do
    bash "$profile_script" template-ready "$template_name" "$CYDER_SUPPORT" \
      "$revision" "$engine_version" >/dev/null 2>&1 || exit 1
  done
  exit 0
fi

cyder_validate_bottle_prefix() {
  local prefix="$1" root prefix_real root_real
  [[ -d "$prefix" && ! -L "$prefix" ]] || { echo "Bottle prefix must be an existing non-symlink directory: $prefix" >&2; return 1; }
  root="$CYDER_SUPPORT/bottles"
  [[ -d "$root" ]] || { echo "Bottle store is missing: $root" >&2; return 1; }
  root_real="$(cd "$root" && pwd -P)"
  prefix_real="$(cd "$prefix" && pwd -P)"
  case "$prefix_real/" in
    "$root_real"/*) printf '%s\n' "$prefix_real" ;;
    *) echo "Bottle prefix must be inside $root: $prefix" >&2; return 1 ;;
  esac
}

if [[ "$APPLY_SETTINGS_PREFIX_SET" -eq 1 ]]; then
  [[ "$APPLY_SETTINGS_ONLY" -eq 0 ]] || { echo "choose only one settings action" >&2; exit 1; }
  prefix="$(cyder_validate_bottle_prefix "$APPLY_SETTINGS_PREFIX")" || exit 2
  engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  [[ -x "$engine/bin/wine" ]] || { echo "Cyder Wine engine is not ready: $engine" >&2; exit 2; }
  if cyder_has_running_prefix "$prefix" || cyder_profile_has_live_sessions "$prefix"; then
    echo "Cannot apply settings while this bottle is running" >&2
    exit 75
  fi
  apply_status=0
  cyder_apply_user_settings "$engine/bin/wine" "$engine" "$prefix" || apply_status=$?
  cleanup_status=0
  wineserver="$engine/bin/wineserver"
  if [[ -x "$wineserver" ]]; then
    WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -k || cleanup_status=$?
    WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -w || cleanup_status=$?
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "Warning: failed to stop settings wineserver for $prefix (status $cleanup_status)" >&2
  fi
  [[ "$apply_status" -eq 0 ]] || exit "$apply_status"
  [[ "$cleanup_status" -eq 0 ]] || exit "$cleanup_status"
  exit 0
fi

if [[ -n "$SESSION_ACTION" ]]; then
  prefix="$(cyder_validate_bottle_prefix "${SESSION_ARGS[0]}")" || exit 2
  case "$SESSION_ACTION" in
    acquire)
      owner_pid="${SESSION_ARGS[1]}"; msync="${SESSION_ARGS[2]}"; esync="${SESSION_ARGS[3]}"; power="${SESSION_ARGS[4]}"
      [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner_pid" 2>/dev/null || { echo "Session owner PID is not live: $owner_pid" >&2; exit 1; }
      [[ "$msync" == 0 || "$msync" == 1 ]] && [[ "$esync" == 0 || "$esync" == 1 ]] || { echo "Session sync values must be 0 or 1" >&2; exit 1; }
      [[ "$msync" == 1 && "$esync" == 1 ]] && { echo "Session cannot enable both MSync and ESync" >&2; exit 1; }
      [[ "$power" == normal || "$power" == background ]] || { echo "Session power must be normal or background" >&2; exit 1; }
      cyder_session_acquire "$prefix" "$msync" "$esync" "$power" || exit $?
      session_file="$CYDER_SESSION_FILE"
      if ! (sed -i '' "s/^pid=.*/pid=$owner_pid/" "$session_file" 2>/dev/null || sed -i "s/^pid=.*/pid=$owner_pid/" "$session_file"); then
        cyder_session_release "$prefix" "$session_file"
        echo "Failed to assign session owner PID" >&2
        exit 1
      fi
      cyder_write_machine_result sessionFile "$session_file"
      printf '%s\n' "$session_file"
      ;;
    update)
      session_file="${SESSION_ARGS[1]}"; new_pid="${SESSION_ARGS[2]}"
      [[ "$new_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$new_pid" 2>/dev/null || { echo "Session PID is not live: $new_pid" >&2; exit 1; }
      case "$session_file" in "$prefix/.cyder-runtime/sessions/"*.session) ;; *) echo "Invalid session path" >&2; exit 1 ;; esac
      [[ -f "$session_file" && ! -L "$session_file" ]] || { echo "Session file is missing or unsafe" >&2; exit 1; }
      grep -q '^pid=' "$session_file" || { echo "Session file has no PID" >&2; exit 1; }
      tmp="$session_file.tmp.$$"
      if ! sed "s/^pid=.*/pid=$new_pid/" "$session_file" >"$tmp" || ! mv -f "$tmp" "$session_file"; then
        rm -f "$tmp"
        echo "Session PID update failed" >&2
        exit 1
      fi
      ;;
    release)
      session_file="${SESSION_ARGS[1]}"
      case "$session_file" in "$prefix/.cyder-runtime/sessions/"*.session) ;; *) echo "Invalid session path" >&2; exit 1 ;; esac
      [[ -f "$session_file" && ! -L "$session_file" ]] || { echo "Session file is missing or unsafe" >&2; exit 1; }
      cyder_session_release "$prefix" "$session_file"
      ;;
  esac
  exit 0
fi

if [[ "$HAS_RUNNING_EXES" -eq 1 ]]; then
  cyder_set_stage has-running-exes
  if cyder_has_running_exes; then
    exit 0
  fi
  CYDER_DIAGNOSTIC_EXPECTED_EXIT=1
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 && "$LAUNCH_ONLY" -eq 0 ]]; then
  cyder_set_stage rosetta-check
  cyder_ensure_rosetta || exit 1
fi

if [[ "$ENSURE_ROSETTA_ONLY" -eq 1 ]]; then
  exit 0
fi

if [[ "$STOP_ALL" -eq 1 ]]; then
  cyder_set_stage stop-all
  cyder_stop_all_exes
  exit 0
fi

if [[ "$APPLY_SETTINGS_ONLY" -eq 1 ]]; then
  cyder_set_stage settings-apply
  engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  if [[ ! -x "$engine/bin/wine" || ! -f "$CYDER_BOOTSTRAP_MARKER" ]]; then
    echo "Cyder environment is not ready; open Cyder.app to finish setup." >&2
    exit 2
  fi
  cyder_apply_user_settings "$engine/bin/wine" "$engine"
  if [[ "${CYDER_STOP_WINESERVER_AFTER_SETTINGS:-0}" == 1 ]]; then
    WINEPREFIX="$CYDER_SHARED_PREFIX" /usr/bin/arch -x86_64 "$engine/bin/wineserver" -k || true
    WINEPREFIX="$CYDER_SHARED_PREFIX" /usr/bin/arch -x86_64 "$engine/bin/wineserver" -w || true
  fi
  exit 0
fi

if [[ "$HEALTH_CHECK" -eq 1 || "$REBUILD_PREFIX" -eq 1 ]]; then
  cyder_set_stage engine-validation
  if [[ "$REBUILD_PREFIX" -eq 1 ]]; then
    engine="$(cyder_ensure_shared_engine "$ENGINE_SRC")"
    wine="$engine/bin/wine"
    cyder_set_stage bootstrap
    cyder_rebuild_shared_prefix "$wine" "$engine"
  else
    # The native launcher already compared the bundled engine-version.txt with
    # the installed version. Do the same cheap file-based readiness check here;
    # do not stream-decompress the bundled engine archive on every health check.
    cyder_engine_is_ready_for_launch || {
      echo "Cyder environment is not ready; bootstrap is required." >&2
      exit 2
    }
    engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
    wine="$engine/bin/wine"
    cyder_set_stage health-check
    cyder_health_check_prefix "$wine" "$CYDER_SHARED_PREFIX"
  fi
  exit $?
fi

if [[ "$ENSURE_ENGINE_ONLY" -eq 1 ]]; then
  cyder_set_stage engine-extraction
  cyder_ensure_shared_engine "$ENGINE_SRC" >/dev/null
  exit 0
fi

if [[ "$BOOTSTRAP_ONLY" -eq 1 ]]; then
  cyder_set_stage engine-validation
  engine="$(cyder_ensure_shared_engine "$ENGINE_SRC")"
  wine="$engine/bin/wine"
  echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
  echo "BOOTSTRAP_MARKER=$CYDER_BOOTSTRAP_MARKER"
  log_dir="$CYDER_SUPPORT/Logs"
  mkdir -p "$log_dir"
  tmp_log="$(mktemp "${TMPDIR:-/tmp}/cyder-bootstrap.XXXXXX")"
  set +e
  cyder_set_stage bootstrap
  {
    echo "engine=$engine"
    echo "wine=$wine"
    echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
    echo
    cyder_bootstrap_shared_prefix "$wine" "$engine"
  } >"$tmp_log" 2>&1
  status=$?
  set -e
  bootstrap_kind="${CYDER_OPERATION_ERROR_KIND:-}"
  bootstrap_code="${CYDER_OPERATION_ERROR_CODE:-}"
  if [[ "$status" -ne 0 && -z "$bootstrap_kind" ]]; then
    if (( status >= 128 )); then
      bootstrap_kind=signal
      bootstrap_code=CYD-BOOTSTRAP-SIGNAL
    else
      bootstrap_kind=exit
      bootstrap_code=CYD-BOOTSTRAP-EXIT
    fi
  fi
  operation_log="$log_dir/operations/bootstrap-$(date '+%Y%m%d-%H%M%S')-$$.log"
  mkdir -p "$log_dir/operations"
  mv -f "$tmp_log" "$operation_log"
  {
    echo "exit_status=$status"
    echo "result=${bootstrap_kind:-success}"
    echo "error_code=${bootstrap_code:-}"
  } >>"$operation_log"
  ln -sfn "operations/$(basename "$operation_log")" "$log_dir/last-bootstrap.log"
  if [[ "$status" -ne 0 ]]; then
    cp -f "$operation_log" "$log_dir/bootstrap-error.log"
    exit "$status"
  fi
  exit 0
fi

if [[ "$LAUNCH_ONLY" -eq 1 ]]; then
  cyder_set_stage exe-validation
  exe="$(cyder_resolve_exe_from_args "${EXE_ARGS[@]}")" || {
    echo "Missing or invalid .exe for --launch-exe" >&2
    exit 1
  }
  if ! cyder_engine_is_ready_for_launch; then
    echo "Cyder environment is not ready; open Cyder.app to finish setup." >&2
    exit 2
  fi
  wine="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
  cyder_set_stage wine-launch
  cyder_run_wine_exe "$wine" "$exe"
  exit 0
fi

exe=""
if [[ ${#EXE_ARGS[@]} -gt 0 ]]; then
  exe="$(cyder_resolve_exe_from_args "${EXE_ARGS[@]}")" || true
fi

if [[ -z "$exe" && "$DRY_RUN" -eq 0 && "${CYDER_GUI:-0}" != 1 ]]; then
  exe="$(cyder_choose_exe)"
fi

if [[ -z "$exe" ]]; then
  echo "No .exe specified" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  cyder_set_stage dry-run
  wine="$(cyder_wine_bin_for_dry_run "$ENGINE_SRC")"
  echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
  echo "wine=$wine"
  echo "exe=$exe"
  echo "cwd=$(dirname "$exe")"
  exit 0
fi

engine="$(cyder_ensure_shared_engine "$ENGINE_SRC")"
wine="$engine/bin/wine"
cyder_set_stage bootstrap
set +e
cyder_bootstrap_shared_prefix "$wine" "$engine"
bootstrap_status=$?
set -e
if [[ "$bootstrap_status" -ne 0 ]]; then
  cyder_bootstrap_error_dialog "bootstrap failed (exit $bootstrap_status)"
  exit 1
fi
cyder_set_stage wine-launch
cyder_run_wine_exe "$wine" "$exe"
