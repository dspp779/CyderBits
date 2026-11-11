#!/usr/bin/env bash
# Deterministic, reversible cnc-ddraw provisioning for one selected executable.
set -euo pipefail

EXPECTED_VERSION="7.1.0.0"
EXPECTED_ARCHIVE_SHA256="0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908"

EXPECTED_RUNTIME_SHA256="b260f7a0d7005be457671d1af11723362a64bce8a46a7097a3158eb626ba0332"

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

validate_payload() {
  local payload="$1" archive actual entry
  archive="$payload/cnc-ddraw.zip"
  [[ -d "$payload" && ! -L "$payload" && -f "$archive" && ! -L "$archive" ]] || {
    echo "CYD-CNC-001: cnc-ddraw payload is missing or unsafe: $payload" >&2
    return 1
  }
  actual="$(sha256_file "$archive")"
  [[ "$actual" == "$EXPECTED_ARCHIVE_SHA256" || "$actual" == "$EXPECTED_RUNTIME_SHA256" ]] || {
    echo "CYD-CNC-002: cnc-ddraw archive SHA-256 mismatch" >&2
    return 1
  }
  [[ ! -L "$payload/LICENSE" && "$(sha256_file "$payload/LICENSE")" == a705144535bbfccc05e8310c4f8ab5f0b6f0ec2c9371b76ca5a522cf90e031f5 &&
     ! -L "$payload/THIRD-PARTY-NOTICES.txt" && "$(sha256_file "$payload/THIRD-PARTY-NOTICES.txt")" == 1c1c4eeb29ce801472ad8ee0a16717a59a2a4a7affd3baf4bf5070fef37aba11 ]] || {
    echo "CYD-CNC-002: cnc-ddraw license or notices checksum mismatch" >&2
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

command_name="${1:-}"
case "$command_name" in
  verify)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    validate_payload "$2"
    echo "valid=cnc-ddraw@$EXPECTED_VERSION"
    ;;
  install)
    [[ $# -eq 4 ]] || { usage; exit 2; }
    exec /usr/bin/ruby "$(dirname "$0")/cyder-cnc-legacy.rb" install "$2" "$3" "$4"
    ;;
  uninstall)
    [[ $# -eq 3 ]] || { usage; exit 2; }
    exec /usr/bin/ruby "$(dirname "$0")/cyder-cnc-legacy.rb" uninstall - "$2" "$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac
