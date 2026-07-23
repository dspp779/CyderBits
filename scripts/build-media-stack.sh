#!/usr/bin/env bash
# Build only the x86_64 GLib/GStreamer libraries needed by winegstreamer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CX_VERSION=26
INSTALL_DEPS=0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cx) CX_VERSION="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    --install-deps) INSTALL_DEPS=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--cx 26] [--install-deps] [--jobs N]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ "$CX_VERSION" == 26 ]] || {
  echo "The minimal media build is currently validated only with CX26." >&2
  exit 1
}

export CX_VERSION
source "$SCRIPT_DIR/env-x86_64.sh"
"$SCRIPT_DIR/prepare-build-deps.sh" --cx "$CX_VERSION"

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  brew_x86 install meson ninja pcre2 libffi bison pkgconf
fi

MESON="$HOMEBREW_PREFIX/bin/meson"
NINJA="$HOMEBREW_PREFIX/bin/ninja"
SYSTEM_PYTHON=/usr/bin/python3
MESON_PACKAGE="$(find "$HOMEBREW_PREFIX/lib" -type d -path '*/site-packages/mesonbuild' -print -quit 2>/dev/null || true)"
PYTHON_SITE="${MESON_PACKAGE%/mesonbuild}"
GLIB_SRC="$BUILD_DIR/cx$CX_VERSION/sources/glib"
GST_SRC="$BUILD_DIR/cx$CX_VERSION/sources/gstreamer"
MEDIA_BUILD="$BUILD_DIR/cx$CX_VERSION/media"

for required in "$MESON" "$NINJA" "$SYSTEM_PYTHON"; do
  [[ -x "$required" ]] || { echo "Missing build tool: $required" >&2; exit 1; }
done
[[ -n "$MESON_PACKAGE" ]] || {
  echo "Cannot locate Homebrew mesonbuild Python package below $HOMEBREW_PREFIX/lib" >&2
  exit 1
}
for required in "$GLIB_SRC/meson.build" "$GST_SRC/meson.build"; do
  [[ -f "$required" ]] || { echo "Missing CrossOver source: $required" >&2; exit 1; }
done

# CrossOver's GLib source archive omits this pinned submodule.
if [[ ! -f "$GLIB_SRC/subprojects/gvdb/meson.build" ]]; then
  mkdir -p "$GLIB_SRC/subprojects"
  git clone https://gitlab.gnome.org/GNOME/gvdb.git "$GLIB_SRC/subprojects/gvdb"
  git -C "$GLIB_SRC/subprojects/gvdb" checkout 0854af0fdb6d527a8d1999835ac2c5059976c210
fi

BUILD_PATH="$HOMEBREW_PREFIX/opt/bison/bin:/usr/bin:/bin:/usr/sbin:/sbin:$MEDIA_INSTALL/bin:$HOMEBREW_PREFIX/bin"
PC_PATH="$MEDIA_INSTALL/lib/pkgconfig:$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/opt/libffi/lib/pkgconfig:$HOMEBREW_PREFIX/opt/pcre2/lib/pkgconfig"
MESON_CMD=(arch -x86_64 env PATH="$BUILD_PATH" PYTHONPATH="$PYTHON_SITE" PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config" PKG_CONFIG_PATH="$PC_PATH" DYLD_LIBRARY_PATH="$MEDIA_INSTALL/lib" "$SYSTEM_PYTHON" "$MESON")

mkdir -p "$MEDIA_BUILD" "$MEDIA_INSTALL"

"${MESON_CMD[@]}" setup --wipe "$MEDIA_BUILD/glib-build" "$GLIB_SRC" \
  --prefix="$MEDIA_INSTALL" --libdir=lib --buildtype=release \
  -Ddefault_library=shared -Dtests=false -Dinstalled_tests=false -Dnls=disabled \
  -Dman=false -Dgtk_doc=false -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
  -Dbsymbolic_functions=false
"${MESON_CMD[@]}" compile -C "$MEDIA_BUILD/glib-build" -j "$JOBS"
"${MESON_CMD[@]}" install -C "$MEDIA_BUILD/glib-build"

"${MESON_CMD[@]}" setup --wipe "$MEDIA_BUILD/gstreamer-build" "$GST_SRC" \
  --prefix="$MEDIA_INSTALL" --libdir=lib --buildtype=release \
  -Ddefault_library=shared -Dauto_features=disabled -Dbuild-tools-source=system \
  -Dbase=enabled -Dgood=disabled -Dugly=disabled -Dbad=disabled -Dlibav=disabled \
  -Ddevtools=disabled -Dges=disabled -Drtsp_server=disabled -Dpython=disabled \
  -Dtls=disabled -Dlibnice=disabled -Dtests=disabled -Dtools=disabled \
  -Dexamples=disabled -Dintrospection=disabled -Dnls=disabled -Dorc=disabled \
  -Ddoc=disabled -Dgtk_doc=disabled
"${MESON_CMD[@]}" compile -C "$MEDIA_BUILD/gstreamer-build" -j "$JOBS"
"${MESON_CMD[@]}" install -C "$MEDIA_BUILD/gstreamer-build"

for pc in gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0; do
  arch -x86_64 env PKG_CONFIG_PATH="$MEDIA_INSTALL/lib/pkgconfig" \
    "$HOMEBREW_PREFIX/bin/pkg-config" --exists "$pc" || {
      echo "Media stack validation failed: $pc" >&2
      exit 1
    }
done

echo "Minimal CX$CX_VERSION media stack installed: $MEDIA_INSTALL"
