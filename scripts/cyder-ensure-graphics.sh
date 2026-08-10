#!/usr/bin/env bash
# Install bundled DXVK/DXMT payloads outside the shared Wine engine archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyder_graphics_extract() {
  local archive="$1" destination="$2" zstd_bin
  zstd_bin="${CYDER_ZSTD:-$(command -v zstd 2>/dev/null || true)}"
  [[ -x "$zstd_bin" ]] || {
    echo "Missing zstd required to extract graphics payloads" >&2
    return 1
  }
  "$zstd_bin" -d -c "$archive" | tar -xf - -C "$destination"
}

cyder_graphics_source_dir() {
  local candidate
  local -a candidates=(
    "${CYDER_GRAPHICS_SRC:-}"
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

cyder_ensure_graphics() {
  local source_dir runtime_root engine
  source_dir="$(cyder_graphics_source_dir)"
  runtime_root="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
  engine="${CYDER_ENGINES:-$runtime_root/Engines}/${CYDER_ENGINE_NAME:-wine-x86_64}"

  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk
  cyder_install_graphics_payload "$source_dir" "$runtime_root" dxmt

  mkdir -p "$engine/lib"
  rm -rf "$engine/lib/dxvk" "$engine/lib/dxmt"
  ln -sfn "../../../graphics/current-dxvk" "$engine/lib/dxvk"
  ln -sfn "../../../graphics/current-dxmt" "$engine/lib/dxmt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cyder_ensure_graphics "$@"
fi
