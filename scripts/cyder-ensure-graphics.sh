#!/usr/bin/env bash
# Install bundled DXVK/DXMT payloads outside the shared Wine engine archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyder_graphics_find_zstd() {
  local candidate
  local -a candidates=("${CYDER_ZSTD:-}")
  [[ -n "${CYDER_OGOM:-}" ]] && candidates+=("$CYDER_OGOM/tools/zstd/zstd")
  candidates+=(
    "$SCRIPT_DIR/../tools/zstd/zstd"
    "$(command -v zstd 2>/dev/null || true)"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

cyder_graphics_extract() {
  local archive="$1" destination="$2" zstd_bin
  zstd_bin="$(cyder_graphics_find_zstd 2>/dev/null || true)"
  [[ -x "$zstd_bin" ]] || {
    echo "Missing zstd required to extract graphics payloads" >&2
    return 1
  }
  "$zstd_bin" -d -c "$archive" | tar -xf - -C "$destination"
}

cyder_graphics_source_dir() {
  local candidate
  # Explicit override: fail closed when set but missing (do not fall through).
  if [[ -n "${CYDER_GRAPHICS_SRC:-}" ]]; then
    if [[ -d "$CYDER_GRAPHICS_SRC" ]]; then
      printf '%s\n' "$CYDER_GRAPHICS_SRC"
      return 0
    fi
    echo "Missing bundled graphics payloads; set CYDER_GRAPHICS_SRC" >&2
    return 1
  fi

  local -a candidates=(
    "${CYDER_RESOURCES:-}/graphics"
    "${CYDER_APP:-}/Contents/Resources/graphics"
    "${CYDER_OGOM:-}/dist/artifacts/graphics"
    "$SCRIPT_DIR/../dist/artifacts/graphics"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Missing bundled graphics payloads; set CYDER_GRAPHICS_SRC" >&2
  return 1
}

cyder_graphics_read_version() {
  local source_dir="$1" name="$2" version
  version="$(awk 'NF { print $1; exit }' "$source_dir/$name-version.txt")"
  [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Invalid $name graphics version: $version" >&2
    return 1
  }
  printf '%s\n' "$version"
}

cyder_graphics_verify_archive() {
  local source_dir="$1" archive="$2" checksum_file expected actual listed_name
  checksum_file="$source_dir/$3-artifact-sha256.txt"
  read -r expected listed_name <"$checksum_file"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$listed_name" == "$(basename "$archive")" ]] || {
    echo "Invalid graphics checksum sidecar: $checksum_file" >&2
    return 1
  }
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "Graphics archive checksum mismatch: $archive" >&2
    return 1
  }
}

cyder_install_graphics_payload() {
  local source_dir="$1" runtime_root="$2" name="$3"
  local graphics_dir version archive target current temp_link staging
  graphics_dir="$runtime_root/graphics"
  version="$(cyder_graphics_read_version "$source_dir" "$name")"
  archive="$source_dir/$name-$version.tar.zst"
  target="$graphics_dir/$name/$version"
  current="$graphics_dir/current-$name"
  [[ -f "$archive" ]] || {
    echo "Missing bundled $name archive: $archive" >&2
    return 1
  }

  mkdir -p "$graphics_dir/$name"
  if [[ ! -f "$target/.cyder-graphics-version" ]] ||
     [[ "$(<"$target/.cyder-graphics-version")" != "$version" ]]; then
    cyder_graphics_verify_archive "$source_dir" "$archive" "$name"
    staging="$(mktemp -d "$graphics_dir/.${name}.XXXXXX")"
    if ! cyder_graphics_extract "$archive" "$staging" || [[ ! -d "$staging/$name" ]]; then
      rm -rf "$staging"
      echo "Unable to extract bundled $name graphics archive" >&2
      return 1
    fi
    printf '%s\n' "$version" >"$staging/$name/.cyder-graphics-version"
    rm -rf "$target"
    mv "$staging/$name" "$target"
    rmdir "$staging" 2>/dev/null || true
  fi

  temp_link="$graphics_dir/.current-$name.$$"
  ln -s "$name/$version" "$temp_link"
  mv -f -h "$temp_link" "$current"
}

cyder_graphics_relpath() {
  local target="$1" start_dir="$2"
  python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
    "$target" "$start_dir"
}

cyder_engine_under_managed_engines() {
  local engine="$1" engines_root="$2"
  local engine_abs engines_abs
  engine_abs="$(cd "$engine" && pwd -P)"
  engines_abs="$(cd "$engines_root" && pwd -P)"
  [[ "$engine_abs" == "$engines_abs" || "$engine_abs" == "$engines_abs"/* ]]
}

cyder_replace_engine_graphics_link() {
  local link="$1" target="$2" engine="$3" engines_root="$4"
  local relative

  if [[ -L "$link" ]]; then
    rm -f "$link"
  elif [[ -e "$link" ]]; then
    if cyder_engine_under_managed_engines "$engine" "$engines_root"; then
      rm -rf "$link"
    else
      echo "Refusing to replace non-symlink graphics path outside managed Engines: $link" >&2
      return 1
    fi
  fi

  relative="$(cyder_graphics_relpath "$target" "$(dirname "$link")")"
  ln -sfn "$relative" "$link"
}

cyder_ensure_dxmt_winemetal_prefix() {
  local dxmt_root="$1" prefix="$2"
  local arch source destination temporary

  [[ -d "$prefix" ]] || return 0
  for arch in x86_64 i386; do
    source="$dxmt_root/${arch}-windows/winemetal.dll"
    [[ -f "$source" ]] || {
      echo "DXMT payload is missing $arch winemetal.dll: $source" >&2
      return 1
    }
  done
  for arch in x86_64 i386; do
    source="$dxmt_root/${arch}-windows/winemetal.dll"
    destination="$prefix/drive_c/windows/"
    if [[ "$arch" == x86_64 ]]; then
      destination+="system32/winemetal.dll"
    else
      destination+="syswow64/winemetal.dll"
    fi
    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "$(dirname "$destination")/.winemetal.dll.XXXXXX")"
    cp "$source" "$temporary"
    mv -f "$temporary" "$destination"
  done
}

cyder_ensure_graphics() {
  local source_dir runtime_root engines_root engine prefix
  source_dir="$(cyder_graphics_source_dir)"
  runtime_root="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
  engines_root="${CYDER_ENGINES:-$runtime_root/Engines}"
  engine="$engines_root/${CYDER_ENGINE_NAME:-wine-x86_64}"
  prefix="${1:-${CYDER_SHARED_PREFIX:-}}"

  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk2
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxmt

  mkdir -p "$engine/lib" "$engines_root"
  cyder_replace_engine_graphics_link \
    "$engine/lib/dxvk" "$runtime_root/graphics/current-dxvk" "$engine" "$engines_root"
  cyder_replace_engine_graphics_link \
    "$engine/lib/dxvk2" "$runtime_root/graphics/current-dxvk2" "$engine" "$engines_root"
  cyder_replace_engine_graphics_link \
    "$engine/lib/dxmt" "$runtime_root/graphics/current-dxmt" "$engine" "$engines_root"
  cyder_ensure_dxmt_winemetal_prefix "$runtime_root/graphics/current-dxmt" "$prefix"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cyder_ensure_graphics "$@"
fi
