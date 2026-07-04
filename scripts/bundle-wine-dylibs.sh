#!/usr/bin/env bash
# Copy Homebrew runtime dylibs into the Wine prefix and rewrite install names
# to @loader_path so the tree is relocatable (no .brew-x86 required at runtime).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_ROOT="${1:-$WINE_INSTALL}"
UNIX_LIB="$WINE_ROOT/lib/wine/x86_64-unix"
BREW="$HOMEBREW_PREFIX"

[[ -d "$UNIX_LIB" ]] || { echo "Missing $UNIX_LIB" >&2; exit 1; }
[[ -d "$BREW" ]] || { echo "Missing $BREW (needed as source of dylibs)" >&2; exit 1; }

python3 - "$WINE_ROOT" "$BREW" "$UNIX_LIB" <<'PY'
import subprocess, re, shutil, sys
from pathlib import Path

wine_root = Path(sys.argv[1])
brew = Path(sys.argv[2]).resolve()
unix_lib = Path(sys.argv[3])

abs_re = re.compile(r"^\t(.+?) \(compatibility")


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
):
    for candidate in (
        brew / "lib" / name,
        brew / "opt" / "freetype" / "lib" / name,
        brew / "opt" / "gnutls" / "lib" / name,
        brew / "opt" / "libpng" / "lib" / name,
        unix_lib / name,
    ):
        if candidate.exists():
            seeds.append(candidate.resolve())
            break

# follow any existing symlinks already in unix lib
for p in unix_lib.iterdir():
    if p.suffix == ".dylib":
        try:
            seeds.append(p.resolve())
        except FileNotFoundError:
            pass

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
    try:
        p.relative_to(brew)
    except ValueError:
        # allow already-bundled copies under wine_root
        try:
            p.relative_to(wine_root)
        except ValueError:
            continue
    seen_files.add(p)
    iid = install_id(p)
    base = Path(iid).name
    # prefer real cellar file
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
        try:
            dp.relative_to(brew)
        except ValueError:
            continue
        queue.append(dp)

print(f"Bundling {len(need)} dylibs into {unix_lib}")

# Remove old symlinks/files we will replace
for base in need:
    target = unix_lib / base
    if target.is_symlink() or target.exists():
        target.unlink()

# Copy (clear quarantine / immutable flags so codesign and xattr work)
for base, src in sorted(need.items()):
    dst = unix_lib / base
    shutil.copy2(src, dst)
    dst.chmod(0o755)
    subprocess.call(["chflags", "nouchg", str(dst)], stderr=subprocess.DEVNULL)
    subprocess.call(["xattr", "-c", str(dst)], stderr=subprocess.DEVNULL)
    print(f"  copy {src.name} -> {dst.name}")

# Rewrite install names
bundled = {base: unix_lib / base for base in need}
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

# Verify no remaining references into brew-x86
bad = []
for base, dst in bundled.items():
    for dep in otool_deps(dst):
        if ".brew-x86" in dep or str(brew) in dep:
            bad.append((base, dep))

if bad:
    print("ERROR: unresolved brew paths remain:", file=sys.stderr)
    for b, d in bad:
        print(f"  {b} -> {d}", file=sys.stderr)
    sys.exit(1)

print("OK: runtime dylibs are relocatable under", unix_lib)
PY
