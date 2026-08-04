#!/usr/bin/env bash
# Build Cyder.app for the test or release channel (sign / notarize / zip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANNEL=""
OUT_DIR="$ROOT/dist"
ENGINE_ARCHIVE=""
APP_VERSION=""
SIGN_IDENTITY_OVERRIDE=""
NOTARY_PROFILE="${CYDER_NOTARY_PROFILE:-cyder-notary}"
DRY_RUN=0
SKIP_NOTARIZE=0
SKIP_BUILD=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --channel test|release [options]

Channels:
  test      Ad-hoc sign only (unless --sign-identity). Default version
            suffix -dev. No notarization.
  release   Developer ID + notarize + staple + publish zip. Requires pinned
            engine (or --engine-archive) and a Developer ID identity.

Options:
  --channel CHANNEL       test | release (required)
  --version VERSION       CFBundle version (test default: 0.9.4-dev;
                          release default: 0.9.4 or CYDER_APP_VERSION)
  --engine-archive PATH   Bundle this engine tarball (else pinned config path)
  --sign-identity ID      codesign identity ('-' for ad-hoc). test defaults to
                          '-'; release defaults to Developer ID Application.
  --out-dir DIR           Output directory (default: dist/)
  --notary-profile NAME   notarytool keychain profile (default: cyder-notary)
  --skip-notarize         release: build+sign only (no notary/staple/zip)
  --skip-build            release: notarize/staple/zip an existing Cyder.app
  --dry-run               Print actions without running them
  -h, --help              Show help

Environment:
  CYDER_APP_VERSION       Same as --version
  CYDER_NOTARY_PROFILE    Same as --notary-profile
  SIGN_IDENTITY           Used on release when --sign-identity is omitted;
                          ignored on test unless --sign-identity is passed
EOF
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --version)
      APP_VERSION="${2:-}"
      shift 2
      ;;
    --engine-archive)
      ENGINE_ARCHIVE="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY_OVERRIDE="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$CHANNEL" in
  test | release) ;;
  "")
    echo "--channel is required (test|release)" >&2
    usage >&2
    exit 1
    ;;
  *)
    echo "Unknown channel: $CHANNEL (expected test|release)" >&2
    exit 1
    ;;
esac

APP="$OUT_DIR/Cyder.app"
DEFAULT_RELEASE_IDENTITY="Developer ID Application: Chun Ho Kwok (3U9565WWM2)"

resolve_pinned_engine() {
  local archive_file="$ROOT/config/cyder-engine-archive.txt"
  local path=""
  [[ -f "$archive_file" ]] || return 1
  path="$(tr -d '[:space:]' <"$archive_file")"
  [[ "$path" = /* ]] || path="$ROOT/$path"
  [[ -f "$path" ]] || return 1
  printf '%s\n' "$path"
}

require_developer_id() {
  local id="${SIGN_IDENTITY:-$DEFAULT_RELEASE_IDENTITY}"
  # A leftover SIGN_IDENTITY=- from test builds must not block release; fall back
  # to the project Developer ID unless the caller passed --sign-identity.
  if [[ "$id" == "-" ]]; then
    if [[ -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
      echo "release channel refuses SIGN_IDENTITY=- (use --channel test)" >&2
      exit 1
    fi
    id="$DEFAULT_RELEASE_IDENTITY"
  fi
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$id"; then
    echo "Developer ID identity not found in keychain: $id" >&2
    echo "See docs/release-signing.zh-TW.md for import steps." >&2
    exit 1
  fi
  export SIGN_IDENTITY="$id"
}

build_app() {
  local -a cmd=(bash "$ROOT/scripts/create-cyder-app.sh")
  if [[ -n "$ENGINE_ARCHIVE" ]]; then
    cmd+=(--engine-archive "$ENGINE_ARCHIVE")
  fi
  cmd+=("$OUT_DIR")
  echo "==> Building Cyder.app (channel=$CHANNEL version=$CYDER_APP_VERSION)"
  run env CYDER_APP_VERSION="$CYDER_APP_VERSION" \
    CYDER_REQUIRE_NATIVE_SWIFT="$([[ "$CHANNEL" == release ]] && echo 1 || echo 0)" \
    SIGN_IDENTITY="$SIGN_IDENTITY" "${cmd[@]}"
}

verify_release_app_contract() {
  local swift="$APP/Contents/MacOS/CyderSwift" actual_version
  [[ -d "$APP" && -f "$swift" ]] || {
    echo "Release app is incomplete: $APP" >&2
    exit 1
  }
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$actual_version" == "$CYDER_APP_VERSION" ]] || {
    echo "Release app version mismatch: expected $CYDER_APP_VERSION, got ${actual_version:-missing}" >&2
    exit 1
  }
  /usr/bin/file -b "$swift" | grep -q 'Mach-O' || {
    echo "Release app requires native CyderSwift; shell fallback found." >&2
    exit 1
  }
  /usr/bin/lipo "$swift" -verify_arch x86_64 arm64 >/dev/null || {
    echo "Release CyderSwift is not universal (x86_64 + arm64)." >&2
    exit 1
  }
}

notarize_and_zip() {
  local zip_submit="$OUT_DIR/Cyder-notarize.zip"
  local zip_publish="$OUT_DIR/Cyder.app.zip"
  [[ -d "$APP" ]] || {
    echo "Missing $APP" >&2
    exit 1
  }

  echo "==> Verifying signature"
  run codesign --verify --deep --strict --verbose=2 "$APP"

  echo "==> Submitting for notarization (profile=$NOTARY_PROFILE)"
  run rm -f "$zip_submit"
  run ditto -c -k --keepParent "$APP" "$zip_submit"
  run xcrun notarytool submit "$zip_submit" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling ticket"
  run xcrun stapler staple "$APP"
  run xcrun stapler validate "$APP"

  echo "==> Publishing zip (after staple)"
  run rm -f "$zip_publish"
  run ditto -c -k --keepParent "$APP" "$zip_publish"

  echo "==> Gatekeeper check"
  run spctl -a -vv "$APP"

  echo "==> Release artifacts"
  echo "    app: $APP"
  echo "    zip: $zip_publish"
}

case "$CHANNEL" in
  test)
    # Always ad-hoc unless --sign-identity is passed (do not inherit a shell
    # SIGN_IDENTITY meant for release builds).
    if [[ -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
      export SIGN_IDENTITY="$SIGN_IDENTITY_OVERRIDE"
    else
      export SIGN_IDENTITY=-
    fi
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
      echo "NOTE: test channel with non-adhoc SIGN_IDENTITY=$SIGN_IDENTITY (no notarization)"
    fi
    CYDER_APP_VERSION="${APP_VERSION:-${CYDER_APP_VERSION:-0.9.4-dev}}"
    export CYDER_APP_VERSION
    if [[ "$SKIP_BUILD" -eq 1 ]]; then
      echo "test channel ignores --skip-build (nothing to notarize)" >&2
    fi
    build_app
    echo "==> Test build ready: $APP"
    echo "    Ad-hoc / non-notarized. Not for public download."
    ;;
  release)
    if [[ -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
      export SIGN_IDENTITY="$SIGN_IDENTITY_OVERRIDE"
    fi
    CYDER_APP_VERSION="${APP_VERSION:-${CYDER_APP_VERSION:-0.9.4}}"
    export CYDER_APP_VERSION
    [[ "$CYDER_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "Release channel requires a stable semantic version: $CYDER_APP_VERSION" >&2
      exit 1
    }
    require_developer_id
    if [[ -z "$ENGINE_ARCHIVE" ]]; then
      if ! ENGINE_ARCHIVE="$(resolve_pinned_engine)"; then
        echo "Missing pinned engine archive (config/cyder-engine-archive.txt)." >&2
        echo "Import with scripts/import-engine-release.sh --apply or pass --engine-archive." >&2
        exit 1
      fi
      echo "==> Using pinned engine: $ENGINE_ARCHIVE"
    fi
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
      build_app
    else
      echo "==> Skipping build; using existing $APP"
    fi
    verify_release_app_contract
    if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
      echo "==> Skipping notarization (--skip-notarize)"
      run codesign --verify --deep --strict --verbose=2 "$APP"
      echo "==> Signed app ready (not notarized): $APP"
    else
      notarize_and_zip
    fi
    ;;
esac
