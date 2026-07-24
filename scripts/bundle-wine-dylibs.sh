#!/usr/bin/env bash
# Copy Homebrew runtime dylibs into the Wine prefix and rewrite install names
# to @loader_path so the tree is relocatable (no .brew-x86 required at runtime).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_ROOT="${1:-$WINE_INSTALL}"
UNIX_LIB="$WINE_ROOT/lib/wine/x86_64-unix"
BREW="$HOMEBREW_PREFIX"
GRAPHICS_LIB="${GRAPHICS_INSTALL:-}/lib"
MEDIA_LIB="${MEDIA_INSTALL:-}/lib"
VULKAN_MODE="${VULKAN_MODE:-without}"
VULKAN_SOURCE="${VULKAN_SOURCE:-existing}"

[[ -d "$UNIX_LIB" ]] || { echo "Missing $UNIX_LIB" >&2; exit 1; }
[[ -d "$BREW" ]] || { echo "Missing $BREW (needed as source of dylibs)" >&2; exit 1; }

case "$VULKAN_SOURCE" in
  crossover | homebrew | existing) ;;
  *)
    echo "Unknown VULKAN_SOURCE: $VULKAN_SOURCE (expected crossover, homebrew, or existing)" >&2
    exit 1
    ;;
esac

export GRAPHICS_LIB MEDIA_LIB VULKAN_MODE VULKAN_SOURCE

python3 - "$WINE_ROOT" "$BREW" "$UNIX_LIB" <<'PY'
import os
import subprocess, re, shutil, sys
from pathlib import Path

wine_root = Path(sys.argv[1]).resolve()
brew = Path(sys.argv[2]).resolve()
unix_lib = Path(sys.argv[3]).resolve()
graphics_lib = Path(os.environ.get("GRAPHICS_LIB", "")).resolve() if os.environ.get("GRAPHICS_LIB") else None
media_lib = Path(os.environ.get("MEDIA_LIB", "")).resolve() if os.environ.get("MEDIA_LIB") else None
vulkan_mode = os.environ.get("VULKAN_MODE", "without")
vulkan_source = os.environ.get("VULKAN_SOURCE", "existing")

abs_re = re.compile(r"^\t(.+?) \(compatibility")


def allowed_root(p: Path) -> bool:
    p = p.resolve()
    for root in (brew, wine_root):
        try:
            p.relative_to(root)
            return True
        except ValueError:
            pass
    if graphics_lib and graphics_lib.is_dir():
        try:
            p.relative_to(graphics_lib.resolve())
            return True
        except ValueError:
            pass
    if media_lib and media_lib.is_dir():
        try:
            p.relative_to(media_lib.resolve())
            return True
        except ValueError:
            pass
    return False


def otool_deps(path: Path):
    try:
        out = subprocess.check_output(["otool", "-L", str(path)], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return []
    deps = []
    for line in out.splitlines()[1:]:
        m = abs_re.match(line)
        if m:
            deps.append(m.group(1))
    return deps


def install_id(path: Path) -> str:
    deps = otool_deps(path)
    return deps[0] if deps else str(path)


seeds = []
for name in (
    "libfreetype.6.dylib",
    "libgnutls.30.dylib",
    "libpng16.16.dylib",
    "libffi.8.dylib",
):
    for candidate in (
        brew / "lib" / name,
        brew / "opt" / "freetype" / "lib" / name,
        brew / "opt" / "gnutls" / "lib" / name,
        brew / "opt" / "libpng" / "lib" / name,
        brew / "opt" / "libffi" / "lib" / name,
        unix_lib / name,
    ):
        if candidate.exists():
            seeds.append(candidate.resolve())
            break

if vulkan_mode == "with":
    candidates_by_source = {
        # The CrossOver snapshot carries feature-advertising changes required
        # by Wine's Vulkan D3D10/11 backend.  A Homebrew MoltenVK can load but
        # may cap wined3d at feature level 9_3, so never let it silently replace
        # an explicitly selected CrossOver build.
        "crossover": (
            (graphics_lib / "libMoltenVK.dylib") if graphics_lib else None,
            unix_lib / "libMoltenVK.dylib",
        ),
        "homebrew": (
            brew / "opt" / "molten-vk" / "lib" / "libMoltenVK.dylib",
            brew / "lib" / "libMoltenVK.dylib",
            unix_lib / "libMoltenVK.dylib",
        ),
        # Repacking an existing engine must preserve its tested renderer.
        "existing": (
            unix_lib / "libMoltenVK.dylib",
            (graphics_lib / "libMoltenVK.dylib") if graphics_lib else None,
            brew / "opt" / "molten-vk" / "lib" / "libMoltenVK.dylib",
            brew / "lib" / "libMoltenVK.dylib",
        ),
    }
    for candidate in candidates_by_source[vulkan_source]:
        if candidate and candidate.exists():
            seeds.append(candidate.resolve())
            break

if media_lib and media_lib.is_dir():
    for name in (
        "libglib-2.0.0.dylib",
        "libgobject-2.0.0.dylib",
        "libintl.8.dylib",
        "libgstreamer-1.0.0.dylib",
        "libgstbase-1.0.0.dylib",
        "libgstaudio-1.0.0.dylib",
        "libgsttag-1.0.0.dylib",
        "libgstvideo-1.0.0.dylib",
    ):
        candidate = media_lib / name
        if candidate.exists():
            seeds.append(candidate.resolve())

# Follow existing dylibs and the dependencies of every Mach-O Unix module.
# winegstreamer.so is the important non-dylib case: it introduces the bundled
# GLib/GStreamer graph and therefore must be a dependency seed.
for p in unix_lib.iterdir():
    if p.suffix == ".dylib":
        try:
            seeds.append(p.resolve())
        except FileNotFoundError:
            pass
    for dep in otool_deps(p):
        if dep.startswith("/usr/lib/") or dep.startswith("/System/") or dep.startswith("@"):
            continue
        candidate = Path(dep)
        if candidate.exists() and allowed_root(candidate):
            seeds.append(candidate.resolve())

need = {}  # basename(install_id) -> resolved path
queue = list(seeds)
seen_files = set()

while queue:
    p = queue.pop()
    if not p.exists():
        continue
    p = p.resolve()
    if p in seen_files:
        continue
    if not allowed_root(p):
        continue
    seen_files.add(p)
    iid = install_id(p)
    base = Path(iid).name
    # Prefer the purpose-built media stack when basenames collide. GLib's
    # proxy-libintl intentionally has the same install name as gettext's
    # libintl, but exports the g_libintl_* symbols GLib was linked against.
    def source_priority(path: Path) -> int:
        resolved = path.resolve()
        if media_lib and media_lib.is_dir():
            try:
                resolved.relative_to(media_lib.resolve())
                return 30
            except ValueError:
                pass
        if graphics_lib and graphics_lib.is_dir():
            try:
                resolved.relative_to(graphics_lib.resolve())
                return 20
            except ValueError:
                pass
        try:
            resolved.relative_to(brew)
            return 10
        except ValueError:
            return 0

    if base not in need or source_priority(p) > source_priority(need[base]):
        need[base] = p
    for d in otool_deps(p):
        if d.startswith("/usr/lib/") or d.startswith("/System/"):
            continue
        if d.startswith("@"):
            continue
        dp = Path(d)
        if not dp.exists():
            continue
        dp = dp.resolve()
        if not allowed_root(dp):
            continue
        queue.append(dp)

print(f"Bundling {len(need)} dylibs into {unix_lib}")

# Remove old symlinks/files we will replace
for base in need:
    target = unix_lib / base
    if need[base].resolve() == target.resolve():
        continue
    if target.is_symlink() or target.exists():
        target.unlink()

# Copy (clear quarantine / immutable flags so codesign and xattr work)
for base, src in sorted(need.items()):
    dst = unix_lib / base
    if src.resolve() == dst.resolve():
        print(f"  keep {dst.name}")
        continue
    shutil.copy2(src, dst)
    dst.chmod(0o755)
    subprocess.call(["chflags", "nouchg", str(dst)], stderr=subprocess.DEVNULL)
    subprocess.call(["xattr", "-c", str(dst)], stderr=subprocess.DEVNULL)
    print(f"  copy {src} -> {dst.name}")

# Rewrite install names
bundled = {base: unix_lib / base for base in need}

# GLib's proxy-libintl and Homebrew gettext deliberately share the install
# name libintl.8.dylib but export different symbol namespaces. Keep the proxy
# at the canonical name for GLib, and give gettext a private alias for GnuTLS
# and other Homebrew consumers that reference _libintl_*.
gettext_intl = None
for candidate in (
    brew / "opt" / "gettext" / "lib" / "libintl.8.dylib",
    brew / "lib" / "libintl.8.dylib",
):
    if candidate.exists():
        gettext_intl = candidate.resolve()
        break
if gettext_intl and media_lib and (media_lib / "libintl.8.dylib").exists():
    alias = "libintl-gettext.8.dylib"
    alias_dst = unix_lib / alias
    shutil.copy2(gettext_intl, alias_dst)
    alias_dst.chmod(0o755)
    subprocess.call(["chflags", "nouchg", str(alias_dst)], stderr=subprocess.DEVNULL)
    subprocess.call(["xattr", "-c", str(alias_dst)], stderr=subprocess.DEVNULL)
    bundled[alias] = alias_dst
    need[alias] = gettext_intl
    print(f"  copy {gettext_intl} -> {alias}")

# map old absolute prefixes to new basenames
old_to_base = {}
for base, src in need.items():
    old_to_base[str(src)] = base
    old_to_base[install_id(src)] = base
    # also common opt/ paths
    for d in otool_deps(src):
        if Path(d).name == base:
            old_to_base[d] = base

for base, dst in bundled.items():
    subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{base}", str(dst)])
    for dep in otool_deps(dst):
        if dep.startswith("/usr/lib/") or dep.startswith("/System/"):
            continue
        if dep.startswith("@loader_path/") or dep.startswith("@rpath/"):
            continue
        dep_base = Path(dep).name
        if dep_base in bundled:
            subprocess.check_call(
                ["install_name_tool", "-change", dep, f"@loader_path/{dep_base}", str(dst)]
            )
        elif dep in old_to_base:
            b = old_to_base[dep]
            subprocess.check_call(
                ["install_name_tool", "-change", dep, f"@loader_path/{b}", str(dst)]
            )

# Rewrite the consumers too, not just the copied dylibs. In particular,
# winegstreamer.so was linked directly against MEDIA_INSTALL and otherwise
# remains non-relocatable even though its dependencies were copied above.
consumers = []
for candidate in unix_lib.iterdir():
    if candidate.is_file() and otool_deps(candidate):
        consumers.append(candidate)
for consumer in consumers:
    for dep in otool_deps(consumer):
        dep_base = Path(dep).name
        if dep_base in bundled and not dep.startswith("@loader_path/"):
            subprocess.check_call(
                ["install_name_tool", "-change", dep, f"@loader_path/{dep_base}", str(consumer)]
            )

    if "libintl-gettext.8.dylib" in bundled:
        try:
            undefined = subprocess.check_output(["nm", "-u", str(consumer)], text=True,
                                                stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            undefined = ""
        needs_gettext = any(
            symbol.strip().startswith("_libintl_") for symbol in undefined.splitlines()
        )
        if needs_gettext:
            for dep in otool_deps(consumer):
                if Path(dep).name == "libintl.8.dylib":
                    subprocess.check_call([
                        "install_name_tool", "-change", dep,
                        "@loader_path/libintl-gettext.8.dylib", str(consumer)
                    ])

    # Remove build-tree search paths. Missing paths are harmless to the loader,
    # but leak the builder's machine and can mask an incomplete bundle.
    load_commands = subprocess.check_output(["otool", "-l", str(consumer)], text=True)
    rpaths = re.findall(r"\n\s+path (\S+) \(offset \d+\)", load_commands)
    for rpath in rpaths:
        if ".brew-x86" in rpath or (media_lib and str(media_lib.resolve()) in rpath):
            subprocess.check_call(["install_name_tool", "-delete_rpath", rpath, str(consumer)])

# Verify no remaining references into brew-x86
bad = []
for dst in consumers:
    for dep in otool_deps(dst):
        if ".brew-x86" in dep or str(brew) in dep or (media_lib and str(media_lib.resolve()) in dep):
            bad.append((dst.name, dep))

if bad:
    print("ERROR: unresolved brew paths remain:", file=sys.stderr)
    for b, d in bad:
        print(f"  {b} -> {d}", file=sys.stderr)
    sys.exit(1)

# Drop orphaned third-party dylibs left from a previous (broader) seed graph —
# e.g. media/gnutls deps that are no longer reachable after a rebuild/drop.
for p in sorted(unix_lib.iterdir()):
    if p.suffix != ".dylib":
        continue
    if p.name in bundled:
        continue
    print(f"  remove orphan {p.name}")
    p.unlink()

# Product floor gate: every remaining bundled .dylib must have Mach-O minos
# ≤ MACOSX_DEPLOYMENT_TARGET (default 10.15). Bottles built for 14/15 fail here.
def parse_version(v: str):
    parts = []
    for p in v.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def macho_minos(path: Path):
    try:
        out = subprocess.check_output(["otool", "-l", str(path)], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return None
    m = re.search(r"\bminos\s+(\d+(?:\.\d+)*)", out)
    if m:
        return m.group(1)
    m = re.search(
        r"LC_VERSION_MIN_MACOSX.*?^\s+version\s+(\d+(?:\.\d+)*)",
        out,
        re.M | re.S,
    )
    if m:
        return m.group(1)
    return None


floor = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "10.15")
floor_v = parse_version(floor)
high = []
for p in sorted(unix_lib.glob("*.dylib")):
    minos = macho_minos(p)
    if minos is None:
        print(f"WARNING: could not read minos for {p.name}", file=sys.stderr)
        continue
    if parse_version(minos) > floor_v:
        high.append((p.name, minos))

if high:
    print(
        f"ERROR: bundled dylib minos exceeds product floor {floor}:",
        file=sys.stderr,
    )
    for name, minos in high:
        print(f"  {name} minos={minos}", file=sys.stderr)
    print(
        "Rebuild runtime brew formulae via brew_x86_install_runtime / "
        "build-media-stack.sh with MACOSX_DEPLOYMENT_TARGET, or drop the "
        "offending package from the seed graph.",
        file=sys.stderr,
    )
    sys.exit(1)

print("OK: runtime dylibs are relocatable under", unix_lib)
print(f"OK: all bundled dylibs have minos ≤ {floor}")
PY
