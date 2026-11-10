#!/usr/bin/env bash
# Resolve and apply dual-variant MoltenVK (.real symlink) for Cyder012+.
# shellcheck shell=bash
set -euo pipefail

_CYDER_MVK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_CYDER_MVK_DIR/cyder-macos-compat.sh" ]]; then
  # shellcheck source=cyder-macos-compat.sh
  source "$_CYDER_MVK_DIR/cyder-macos-compat.sh"
fi
unset _CYDER_MVK_DIR

# Prints a candidate only; version names never prove host compatibility.
cyder_resolve_moltenvk_variant() {
  local pref="${1:?}"
  case "$pref" in
    1.4.2 | 1.2.10) ;;
    *)
      echo "invalid moltenvk variant: $pref" >&2
      return 2
      ;;
  esac
  if ! cyder_macos_at_least 12 0; then
    printf '1.2.10\n'
    return 0
  fi
  printf '%s\n' "$pref"
}

cyder_moltenvk_unix_lib() {
  local engine="${1:?}"
  printf '%s\n' "$engine/lib/wine/x86_64-unix"
}

# True when the engine ships the Cyder012+ dual layout.
cyder_engine_has_moltenvk_dual_variant() {
  local unix
  unix="$(cyder_moltenvk_unix_lib "${1:?}")"
  [[ -f "$unix/libMoltenVK-1.4.2.dylib" && -f "$unix/libMoltenVK-1.2.10.dylib" && -f "$unix/libMoltenVK.dylib" ]]
}

# Read Mach-O load commands without Apple's developer tools (otool, strings,
# vtool and lipo are Command Line Tools shims on end-user Macs). Uses only
# /usr/bin/perl, which the launch scripts already require. Prints one
# "minos X.Y.Z" line (LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX) and one
# "<load|reexport|weak|lazy|upward> <install name>" line per dylib command for
# the requested slice. Exits non-zero for non-Mach-O, a missing slice or any
# out-of-bounds/truncated structure.
cyder_macho_inspect() {
  local file="${1:?}" arch="${2:-x86_64}"
  /usr/bin/perl -e '
    use strict; use warnings;
    my ($path, $arch) = @ARGV;
    my %cpu = (x86_64 => 0x01000007, arm64 => 0x0100000c);
    defined $cpu{$arch} or die "unsupported arch\n";
    open(my $fh, "<:raw", $path) or die "unreadable\n";
    my $size = -s $fh; defined $size or die "unreadable\n";
    sub rd { my ($fh, $off, $len, $size) = @_;
      die "truncated\n" if $off < 0 || $len < 0 || $off + $len > $size;
      seek($fh, $off, 0) or die "seek\n"; my $b = ""; my $n = read($fh, $b, $len);
      die "truncated\n" unless defined $n && $n == $len; return $b; }
    my $base = 0; my $len = $size;
    my $magic = unpack("N", rd($fh, 0, 4, $size));
    if ($magic == 0xcafebabe || $magic == 0xcafebabf) {
      my $wide = $magic == 0xcafebabf; my $n = unpack("N", rd($fh, 4, 4, $size));
      die "bad fat header\n" if $n < 1 || $n > 64;
      my $entry = $wide ? 32 : 20; my $found = 0;
      for my $i (0 .. $n - 1) {
        my $raw = rd($fh, 8 + $i * $entry, $entry, $size);
        my ($cpu, $off, $sz);
        if ($wide) { my ($c, undef, $oh, $ol, $sh, $sl) = unpack("N N N N N N", $raw);
          ($cpu, $off, $sz) = ($c, $oh * 4294967296 + $ol, $sh * 4294967296 + $sl); }
        else { ($cpu, undef, $off, $sz) = unpack("N N N N", $raw); }
        next unless $cpu == $cpu{$arch};
        die "bad slice\n" if $off + $sz > $size || $sz < 32;
        ($base, $len, $found) = ($off, $sz, 1); last;
      }
      die "missing $arch slice\n" unless $found;
    }
    my ($m, $cpu, undef, undef, $ncmds, $sizeofcmds) = unpack("V6", rd($fh, $base, 24, $size));
    die "not a 64-bit Mach-O\n" unless $m == 0xfeedfacf;
    die "missing $arch slice\n" unless $cpu == $cpu{$arch};
    die "bad load commands\n" if $ncmds > 4096 || 32 + $sizeofcmds > $len;
    my $cmds = rd($fh, $base + 32, $sizeofcmds, $size);
    my %dylib = (0xc => "load", 0x8000001f => "reexport", 0x80000018 => "weak",
                 0x20 => "lazy", 0x80000023 => "upward");
    my ($at, $minos) = (0, undef);
    for (1 .. $ncmds) {
      die "truncated\n" if $at + 8 > length($cmds);
      my ($cmd, $cs) = unpack("V V", substr($cmds, $at, 8));
      die "bad load command\n" if $cs < 8 || $at + $cs > length($cmds);
      my $body = substr($cmds, $at, $cs);
      if (($cmd == 0x32 || $cmd == 0x24) && $cs >= 16) {
        my $v = unpack("V", substr($body, $cmd == 0x32 ? 12 : 8, 4));
        if ($cmd == 0x24 || unpack("V", substr($body, 8, 4)) == 1) {
          $minos //= sprintf("%d.%d.%d", $v >> 16, ($v >> 8) & 0xff, $v & 0xff);
        }
      } elsif (exists $dylib{$cmd} && $cs >= 24) {
        my $name_off = unpack("V", substr($body, 8, 4));
        die "bad dylib name\n" if $name_off < 24 || $name_off >= $cs;
        my $name = substr($body, $name_off); $name =~ s/\0.*\z//s;
        print "$dylib{$cmd} $name\n";
      }
      $at += $cs;
    }
    die "no minimum macOS version\n" unless defined $minos;
    print "minos $minos\n";
  ' "$file" "$arch"
}

cyder_macho_reexports_real() {
  local out
  out="$(cyder_macho_inspect "${1:?}" x86_64 2>/dev/null)" || return 1
  grep -Fxq 'reexport @loader_path/libMoltenVK.real.dylib' <<<"$out"
}

# sets lib/wine/x86_64-unix/libMoltenVK.real.dylib -> libMoltenVK-$resolved.dylib
cyder_apply_moltenvk_variant() {
  local engine="${1:?}" pref="${2:?}" unix resolved target
  unix="$(cyder_moltenvk_unix_lib "$engine")"
  resolved="$(cyder_resolve_moltenvk_variant "$pref")"
  target="libMoltenVK-${resolved}.dylib"
  [[ -f "$unix/$target" ]] || {
    echo "missing $unix/$target" >&2
    return 1
  }
  [[ -f "$unix/libMoltenVK.dylib" ]] || {
    echo "missing $unix/libMoltenVK.dylib" >&2
    return 1
  }
  LC_ALL=C grep -Fqa 'cyder-moltenvk-timeline-wait-poll' "$unix/libMoltenVK.dylib" || {
    echo "libMoltenVK.dylib is not the wait-poll shim" >&2
    return 1
  }
  if ! cyder_macho_reexports_real "$unix/libMoltenVK.dylib"; then
    echo "libMoltenVK.dylib does not re-export libMoltenVK.real.dylib" >&2
    return 1
  fi
  # Refuse double-shim: non-symlink .real must not itself re-export .real.
  if [[ -f "$unix/libMoltenVK.real.dylib" ]] && ! [[ -L "$unix/libMoltenVK.real.dylib" ]]; then
    if cyder_macho_reexports_real "$unix/libMoltenVK.real.dylib"; then
      echo "libMoltenVK.real.dylib looks like a shim (double-shim)" >&2
      return 1
    fi
  fi
  if [[ -L "$unix/libMoltenVK.real.dylib" && "$(readlink "$unix/libMoltenVK.real.dylib")" == "$target" ]]; then
    return 0
  fi
  if [[ -n "${CYDER_EXECUTION_RUNTIME_MUTATION:-}${CYDER_EXECUTION_OWNER_TICKET:-}" && "${CYDER_EXECUTION_RUNTIME_MUTATION:-0}" != 1 ]]; then
    echo "Shared MoltenVK configuration changed; retry the launch to acquire its global operation scope." >&2
    return 75
  fi
  # Running games load the variant lazily; never switch it under them.
  if declare -F cyder_shared_runtime_idle >/dev/null 2>&1; then
    cyder_shared_runtime_idle "$engine" moltenvk || return $?
  fi
  ln -sfn "$target" "$unix/libMoltenVK.real.dylib"
}

# Soft apply: no-op on single-dylib engines (Cyder011 and earlier).
cyder_apply_moltenvk_variant_if_present() {
  local engine="${1:?}" pref="${2:?}"
  if ! cyder_engine_has_moltenvk_dual_variant "$engine"; then
    return 0
  fi
  cyder_apply_moltenvk_variant "$engine" "$pref"
}

cyder_default_moltenvk_variant_preference() {
  if cyder_macos_at_least 12 0; then
    printf '1.4.2\n'
  else
    printf '1.2.10\n'
  fi
}

# Inspect the Wine process slice, including older LC_VERSION_MIN_MACOSX dylibs.
# Fail closed when the file/slice/load command cannot be inspected.
cyder_moltenvk_check_minos() {
  local dylib="${1:?}" info required host
  info="$(cyder_macho_inspect "$dylib" x86_64 2>/dev/null)" || info=""
  required="$(sed -n 's/^minos //p' <<<"$info")"
  if [[ ! "$required" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "DXVK/Vulkan blocked: cannot determine x86_64 Mach-O minOS: $dylib" >&2
    return 1
  fi
  host="$(cyder_macos_product_version)"
  if ! awk -v host="$host" -v need="$required" 'BEGIN {
    split(host,h,"."); split(need,n,".");
    for (i=1;i<=3;i++) { if (h[i]+0 > n[i]+0) exit 0; if (h[i]+0 < n[i]+0) exit 1 }
    exit 0
  }'; then
    echo "DXVK/Vulkan blocked: macOS $host; $dylib requires macOS $required. Choose a compatible engine or another graphics backend." >&2
    return 1
  fi
}

# Call after backend resolution, before spawning Wine. Installation/preference
# maintenance may still select a real on a host using WineD3D or D3DMetal.
cyder_validate_moltenvk_for_backend() {
  local engine="${1:?}" backend="${2:-default}" unix shim real
  [[ "$backend" == dxvk ]] || return 0
  unix="$(cyder_moltenvk_unix_lib "$engine")"
  shim="$unix/libMoltenVK.dylib"
  if [[ ! -e "$shim" && ! -L "$shim" ]]; then
    shim="$engine/lib64/libMoltenVK.dylib"
  fi
  cyder_moltenvk_check_minos "$shim" || return $?
  real="${shim%/*}/libMoltenVK.real.dylib"
  # Old single-dylib engines have no .real. A shim must have a readable real.
  if [[ -e "$real" || -L "$real" ]] ||
     cyder_macho_reexports_real "$shim"; then
    cyder_moltenvk_check_minos "$real" || return $?
  fi
}

# CLI for Swift / manual use.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    resolve)
      cyder_resolve_moltenvk_variant "${2:?}"
      ;;
    apply)
      cyder_apply_moltenvk_variant "${2:?}" "${3:?}"
      ;;
    apply-if-present)
      cyder_apply_moltenvk_variant_if_present "${2:?}" "${3:?}"
      ;;
    *)
      echo "Usage: $0 resolve|apply|apply-if-present …" >&2
      exit 2
      ;;
  esac
fi
