#!/usr/bin/env bash
# Cyder launcher — open Windows EXE with shared prefix (no Python).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$SCRIPT_DIR/cyder-common.sh"

if cyder_resources_has_bundled_engine "$(dirname "$SCRIPT_DIR")"; then
  cyder_init_paths "$(dirname "$SCRIPT_DIR")"
else
  cyder_init_paths "$SCRIPT_DIR"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [game.exe ...]

Options:
  --engine-src PATH   Wine engine source (default: install/wine-cx26-x86_64 or app payload)
  --dry-run           Print paths without installing engine or launching
  --bootstrap-only    Bootstrap shared prefix (mono, tar, hi-res) and exit
  --ensure-engine-only  Install shared engine from payload/tarball and exit
  --ensure-rosetta-only Check Rosetta 2 on Apple Silicon and exit
  --stop-all          Stop all EXEs in the Cyder shared prefix and exit
  --has-running-exes  Exit 0 if the shared prefix has running EXEs, otherwise 1
  --launch-exe PATH   Launch .exe (engine + bootstrap must already be ready)
  -h, --help          Show this help
EOF
}

DRY_RUN=0
BOOTSTRAP_ONLY=0
ENSURE_ENGINE_ONLY=0
ENSURE_ROSETTA_ONLY=0
STOP_ALL=0
HAS_RUNNING_EXES=0
LAUNCH_ONLY=0
ENGINE_SRC="$CYDER_ENGINE_SRC"
EXE_ARGS=()

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
    --launch-exe)
      [[ $# -ge 2 ]] || {
        echo "--launch-exe requires PATH" >&2
        exit 1
      }
      LAUNCH_ONLY=1
      EXE_ARGS+=("$2")
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
      shift
      ;;
  esac
done

if [[ "$HAS_RUNNING_EXES" -eq 1 ]]; then
  cyder_has_running_exes
  exit $?
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  cyder_ensure_rosetta || exit 1
fi

if [[ "$ENSURE_ROSETTA_ONLY" -eq 1 ]]; then
  exit 0
fi

if [[ "$STOP_ALL" -eq 1 ]]; then
  cyder_stop_all_exes
  exit 0
fi

if [[ "$ENSURE_ENGINE_ONLY" -eq 1 ]]; then
  cyder_ensure_shared_engine "$ENGINE_SRC" >/dev/null
  exit 0
fi

if [[ "$BOOTSTRAP_ONLY" -eq 1 ]]; then
  engine="$(cyder_ensure_shared_engine "$ENGINE_SRC")"
  wine="$engine/bin/wine"
  echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
  echo "BOOTSTRAP_MARKER=$CYDER_BOOTSTRAP_MARKER"
  log_dir="$CYDER_SUPPORT/Logs"
  mkdir -p "$log_dir"
  tmp_log="$(mktemp "${TMPDIR:-/tmp}/cyder-bootstrap.XXXXXX")"
  set +e
  {
    echo "engine=$engine"
    echo "wine=$wine"
    echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
    echo
    cyder_bootstrap_shared_prefix "$wine" "$engine"
  } >"$tmp_log" 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    mv -f "$tmp_log" "$log_dir/bootstrap-error.log"
    exit "$status"
  fi
  rm -f "$tmp_log"
  exit 0
fi

if [[ "$LAUNCH_ONLY" -eq 1 ]]; then
  exe="$(cyder_resolve_exe_from_args "${EXE_ARGS[@]}")" || {
    echo "Missing or invalid .exe for --launch-exe" >&2
    exit 1
  }
  engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  if [[ ! -x "$engine/bin/wine" || ! -f "$CYDER_BOOTSTRAP_MARKER" ]] \
    || cyder_engine_needs_install "$ENGINE_SRC"; then
    echo "Cyder environment is not ready; open Cyder.app to finish setup." >&2
    exit 2
  fi
  wine="$engine/bin/wine"
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
  wine="$(cyder_wine_bin_for_dry_run "$ENGINE_SRC")"
  echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
  echo "wine=$wine"
  echo "exe=$exe"
  echo "cwd=$(dirname "$exe")"
  exit 0
fi

engine="$(cyder_ensure_shared_engine "$ENGINE_SRC")"
wine="$engine/bin/wine"
set +e
cyder_bootstrap_shared_prefix "$wine" "$engine"
bootstrap_status=$?
set -e
if [[ "$bootstrap_status" -ne 0 ]]; then
  cyder_bootstrap_error_dialog "bootstrap failed (exit $bootstrap_status)"
  exit 1
fi
cyder_run_wine_exe "$wine" "$exe"
