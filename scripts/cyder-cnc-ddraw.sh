#!/usr/bin/env bash
# Deterministic, reversible cnc-ddraw provisioning for one selected executable.
set -euo pipefail

EXPECTED_VERSION="7.1.0.0"
EXPECTED_ARCHIVE_SHA256="0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908"

usage() {
  cat >&2 <<EOF
usage:
  $(basename "$0") verify PAYLOAD_DIR
  $(basename "$0") install PAYLOAD_DIR EXE BOTTLE
  $(basename "$0") uninstall EXE BOTTLE
EOF
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

exe_identity() {
  printf '%s' "$1" | /usr/bin/shasum -a 256 | awk '{print $1}'
}

validate_payload() {
  local payload="$1" archive actual entry
  archive="$payload/cnc-ddraw.zip"
  [[ -d "$payload" && ! -L "$payload" && -f "$archive" && ! -L "$archive" ]] || {
    echo "CYD-CNC-001: cnc-ddraw payload is missing or unsafe: $payload" >&2
    return 1
  }
  actual="$(sha256_file "$archive")"
  [[ "$actual" == "$EXPECTED_ARCHIVE_SHA256" ]] || {
    echo "CYD-CNC-002: cnc-ddraw archive SHA-256 mismatch" >&2
    return 1
  }
  while IFS= read -r entry; do
    case "$entry" in
      "cnc-ddraw config.exe" | ddraw.dll | ddraw.ini | Shaders/ | Shaders/*) ;;
      *)
        echo "CYD-CNC-003: unexpected cnc-ddraw archive entry: $entry" >&2
        return 1
        ;;
    esac
    case "$entry" in
      /* | *"/../"* | ../* | *"/.." )
        echo "CYD-CNC-003: unsafe cnc-ddraw archive entry: $entry" >&2
        return 1
        ;;
    esac
  done < <(/usr/bin/unzip -Z1 "$archive")
}

resolve_target() {
  local exe="$1" directory basename
  [[ -f "$exe" && ! -L "$exe" ]] || {
    echo "CYD-CNC-004: executable is missing or unsafe: $exe" >&2
    return 1
  }
  directory="$(cd "$(dirname "$exe")" && pwd -P)"
  basename="$(basename "$exe")"
  [[ -f "$directory/$basename" && ! -L "$directory/$basename" ]] || {
    echo "CYD-CNC-004: executable changed while resolving it: $exe" >&2
    return 1
  }
  printf '%s\n' "$directory/$basename"
}

state_directory() {
  local exe="$1" bottle="$2" key root
  [[ -d "$bottle" && ! -L "$bottle" ]] || {
    echo "CYD-CNC-005: bottle is missing or unsafe: $bottle" >&2
    return 1
  }
  key="$(exe_identity "$exe")"
  root="$bottle/.cyder-runtime/packages"
  [[ ! -L "$bottle/.cyder-runtime" && ! -L "$root" ]] || {
    echo "CYD-CNC-005: bottle package state path is unsafe" >&2
    return 1
  }
  mkdir -p "$root"
  printf '%s\n' "$root/cnc-ddraw-$key"
}

install_payload() {
  local payload="$1" exe="$2" bottle="$3"
  local target game_dir archive state staging manifest tmp
  local relative hash
  validate_payload "$payload"
  target="$(resolve_target "$exe")"
  game_dir="$(dirname "$target")"
  archive="$payload/cnc-ddraw.zip"
  state="$(state_directory "$target" "$bottle")"
  manifest="$state/manifest.tsv"

  if [[ -f "$manifest" && ! -L "$manifest" ]]; then
    grep -Fxq "version=$EXPECTED_VERSION" "$manifest" &&
      grep -Fxq "executable=$target" "$manifest" || {
        echo "CYD-CNC-006: existing cnc-ddraw state does not match this executable" >&2
        return 1
      }
    [[ -f "$game_dir/ddraw.dll" && -f "$game_dir/ddraw.ini" &&
       -d "$game_dir/Shaders" ]] || {
      echo "CYD-CNC-007: managed cnc-ddraw installation is incomplete" >&2
      return 1
    }
    echo "installed=cnc-ddraw@$EXPECTED_VERSION executable=$target unchanged=true"
    return 0
  fi

  for relative in ddraw.dll ddraw.ini Shaders; do
    [[ ! -e "$game_dir/$relative" && ! -L "$game_dir/$relative" ]] || {
      echo "CYD-CNC-008: refusing to overwrite unmanaged $game_dir/$relative" >&2
      return 1
    }
  done

  staging="$(mktemp -d "$game_dir/.cyder-cnc-ddraw-staging.XXXXXX")"
  trap '[[ -z "${staging:-}" ]] || rm -rf "$staging"' RETURN
  /usr/bin/unzip -q "$archive" ddraw.dll ddraw.ini 'Shaders/*' -d "$staging"
  [[ -f "$staging/ddraw.dll" && -f "$staging/ddraw.ini" &&
     -d "$staging/Shaders" ]] || {
    echo "CYD-CNC-009: cnc-ddraw archive is incomplete" >&2
    return 1
  }
  if find "$staging" -type l | grep -q .; then
    echo "CYD-CNC-009: cnc-ddraw archive contains symbolic links" >&2
    return 1
  fi

  mkdir -p "$state"
  [[ ! -L "$state" ]] || {
    echo "CYD-CNC-005: cnc-ddraw state directory is unsafe" >&2
    return 1
  }
  tmp="$state/manifest.tsv.tmp.$$"
  {
    printf 'schema=1\nversion=%s\narchive_sha256=%s\nexecutable=%s\n' \
      "$EXPECTED_VERSION" "$EXPECTED_ARCHIVE_SHA256" "$target"
    while IFS= read -r relative; do
      relative="${relative#"$staging/"}"
      hash="$(sha256_file "$staging/$relative")"
      printf 'file\t%s\t%s\n' "$hash" "$relative"
    done < <(find "$staging" -type f | LC_ALL=C sort)
  } >"$tmp"

  mv "$staging/ddraw.dll" "$game_dir/ddraw.dll"
  mv "$staging/ddraw.ini" "$game_dir/ddraw.ini"
  mv "$staging/Shaders" "$game_dir/Shaders"
  if ! mv "$tmp" "$manifest"; then
    rm -rf "$game_dir/ddraw.dll" "$game_dir/ddraw.ini" "$game_dir/Shaders"
    return 1
  fi
  chmod 600 "$manifest"
  rm -rf "$staging"
  trap - RETURN
  echo "installed=cnc-ddraw@$EXPECTED_VERSION executable=$target"
}

uninstall_payload() {
  local exe="$1" bottle="$2"
  local target game_dir state manifest kind hash relative actual
  local preserved=0
  target="$(resolve_target "$exe")"
  game_dir="$(dirname "$target")"
  state="$(state_directory "$target" "$bottle")"
  manifest="$state/manifest.tsv"
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    echo "CYD-CNC-010: no managed cnc-ddraw installation for $target" >&2
    return 1
  }
  grep -Fxq "executable=$target" "$manifest" || {
    echo "CYD-CNC-006: cnc-ddraw state belongs to another executable" >&2
    return 1
  }

  while IFS=$'\t' read -r kind hash relative; do
    [[ "$kind" == file ]] || continue
    case "$relative" in
      ddraw.dll | ddraw.ini | Shaders/*) ;;
      *)
        echo "CYD-CNC-011: refusing unsafe manifest path: $relative" >&2
        return 1
        ;;
    esac
    [[ -f "$game_dir/$relative" && ! -L "$game_dir/$relative" ]] || continue
    actual="$(sha256_file "$game_dir/$relative")"
    if [[ "$actual" == "$hash" ]]; then
      rm -f "$game_dir/$relative"
    else
      echo "preserved modified cnc-ddraw file: $game_dir/$relative" >&2
      preserved=1
    fi
  done <"$manifest"
  find "$game_dir/Shaders" -depth -type d -empty -delete 2>/dev/null || true
  if [[ "$preserved" -eq 0 ]]; then
    rm -f "$manifest"
    rmdir "$state" 2>/dev/null || true
  fi
  echo "uninstalled=cnc-ddraw@$EXPECTED_VERSION executable=$target preserved_modified=$preserved"
}

command_name="${1:-}"
case "$command_name" in
  verify)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    validate_payload "$2"
    echo "valid=cnc-ddraw@$EXPECTED_VERSION"
    ;;
  install)
    [[ $# -eq 4 ]] || { usage; exit 2; }
    install_payload "$2" "$3" "$4"
    ;;
  uninstall)
    [[ $# -eq 3 ]] || { usage; exit 2; }
    uninstall_payload "$2" "$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac
