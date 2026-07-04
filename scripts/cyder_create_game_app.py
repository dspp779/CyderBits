#!/usr/bin/env python3
"""Create a macOS .app that launches a Windows EXE via Cyder's Wine engine."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

# When launched from Cyder.app, Resources/ is OGOM-like and scripts live in ogom-scripts/.
_HERE = Path(__file__).resolve().parent
if (_HERE / "engine-payload").is_dir():
    OGOM = _HERE
    SCRIPTS = Path(os.environ.get("CYDER_SCRIPTS", _HERE / "ogom-scripts"))
    DEFAULT_ENGINE_SRC = Path(os.environ.get("CYDER_ENGINE_SRC", _HERE / "engine-payload"))
    ENTITLEMENTS = _HERE / "entitlements.plist"
else:
    OGOM = _HERE.parent
    SCRIPTS = Path(os.environ.get("CYDER_SCRIPTS", OGOM / "scripts"))
    DEFAULT_ENGINE_SRC = Path(os.environ.get("CYDER_ENGINE_SRC", OGOM / "install" / "wine-x86_64"))
    ENTITLEMENTS = OGOM / "config" / "entitlements.plist"

SUPPORT = Path.home() / "Library" / "Application Support" / "Cyder"
ENGINES = SUPPORT / "Engines"
BOTTLES = SUPPORT / "Bottles"
ENGINE_NAME = "wine-x86_64"


def run(cmd: list[str], **kw) -> None:
    print("+", " ".join(str(c) for c in cmd))
    subprocess.check_call(cmd, **kw)


def osascript(script: str) -> str:
    out = subprocess.check_output(["osascript", "-e", script], text=True)
    return out.strip()


def choose_exe() -> Path:
    script = (
        'set f to choose file with prompt "選擇 Windows 遊戲執行檔 (.exe)" '
        'of type {"com.microsoft.windows-executable", "exe", "public.executable"}'
        "\nPOSIX path of f"
    )
    try:
        return Path(osascript(script)).expanduser()
    except subprocess.CalledProcessError as e:
        sys.exit("已取消選檔" if e.returncode else 1)


def choose_output_dir(default: Path) -> Path:
    script = (
        f'set d to choose folder with prompt "選擇遊戲 App 儲存位置" '
        f'default location POSIX file "{default}"'
        "\nPOSIX path of d"
    )
    try:
        return Path(osascript(script)).expanduser()
    except subprocess.CalledProcessError:
        return default


def ask_yes_no(prompt: str, default_no: bool = True) -> bool:
    default = "No" if default_no else "Yes"
    alt = "Yes" if default_no else "No"
    script = (
        f'display dialog "{prompt}" buttons {{"{alt}", "{default}"}} '
        f'default button "{default}" with title "Cyder"'
        f"\nbutton returned of result"
    )
    try:
        return osascript(script) == "Yes"
    except subprocess.CalledProcessError:
        return not default_no


def slugify(name: str) -> str:
    s = re.sub(r"[^\w\-]+", "-", name, flags=re.UNICODE).strip("-").lower()
    return (s or "game")[:40]


def _pe_rva_to_offset(data: bytes, rva: int, sections: list[tuple[int, int, int]]) -> int | None:
    for va, size, raw in sections:
        if va <= rva < va + max(size, 1):
            return raw + (rva - va)
    return None


def _pe_parse_sections(data: bytes) -> tuple[list[tuple[int, int, int]], int] | None:
    if len(data) < 0x40 or data[:2] != b"MZ":
        return None
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if e_lfanew + 24 > len(data) or data[e_lfanew : e_lfanew + 4] != b"PE\0\0":
        return None
    coff = e_lfanew + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    if opt + opt_size > len(data):
        return None
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic == 0x10B:  # PE32
        dd_off = opt + 96
    elif magic == 0x20B:  # PE32+
        dd_off = opt + 112
    else:
        return None
    if dd_off + 24 > len(data):
        return None
    res_rva, _res_size = struct.unpack_from("<II", data, dd_off + 16)
    if res_rva == 0:
        return None
    sec_off = opt + opt_size
    sections: list[tuple[int, int, int]] = []
    for i in range(num_sections):
        off = sec_off + i * 40
        if off + 40 > len(data):
            break
        # VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData
        vsize, va, raw_size, raw = struct.unpack_from("<IIII", data, off + 8)
        sections.append((va, max(vsize, raw_size), raw))
    return sections, res_rva


def _pe_read_res_dir(data: bytes, offset: int) -> list[tuple[int, int, bool]]:
    """Return (id_or_name, offset, is_directory) entries."""
    if offset + 16 > len(data):
        return []
    _chars, _time, _maj, _min, n_named, n_id = struct.unpack_from("<IIHHHH", data, offset)
    entries = []
    base = offset + 16
    for i in range(n_named + n_id):
        ent = base + i * 8
        if ent + 8 > len(data):
            break
        name, off = struct.unpack_from("<II", data, ent)
        is_dir = bool(off & 0x80000000)
        entries.append((name, off & 0x7FFFFFFF, is_dir))
    return entries


def _pe_resource_data(data: bytes, sections: list[tuple[int, int, int]], res_rva: int, path_ids: list[int]) -> bytes | None:
    """Walk resource tree by numeric IDs (type, name, lang)."""
    root_off = _pe_rva_to_offset(data, res_rva, sections)
    if root_off is None:
        return None
    offset = root_off
    for depth, want_id in enumerate(path_ids):
        entries = _pe_read_res_dir(data, offset)
        match = None
        for name, ent_off, is_dir in entries:
            # High bit of name means string name; skip named entries for ID walk.
            if name & 0x80000000:
                continue
            if name == want_id:
                match = (ent_off, is_dir)
                break
        if match is None:
            # Prefer first entry when language not found.
            if depth == len(path_ids) - 1 and entries:
                ent_off, is_dir = entries[0][1], entries[0][2]
                match = (ent_off, is_dir)
            else:
                return None
        ent_off, is_dir = match
        if depth < len(path_ids) - 1:
            if not is_dir:
                return None
            offset = root_off + ent_off
        else:
            # Data entry (or one more lang directory)
            if is_dir:
                lang_entries = _pe_read_res_dir(data, root_off + ent_off)
                if not lang_entries:
                    return None
                ent_off = lang_entries[0][1]
                is_dir = lang_entries[0][2]
                if is_dir:
                    return None
            data_ent = root_off + ent_off
            if data_ent + 16 > len(data):
                return None
            data_rva, size, _codepage, _reserved = struct.unpack_from("<IIII", data, data_ent)
            file_off = _pe_rva_to_offset(data, data_rva, sections)
            if file_off is None or file_off + size > len(data):
                return None
            return data[file_off : file_off + size]
    return None


def _pe_list_ids(data: bytes, sections: list[tuple[int, int, int]], res_rva: int, type_id: int) -> list[int]:
    root_off = _pe_rva_to_offset(data, res_rva, sections)
    if root_off is None:
        return []
    for name, ent_off, is_dir in _pe_read_res_dir(data, root_off):
        if name & 0x80000000 or name != type_id or not is_dir:
            continue
        ids = []
        for n2, _e2, _d2 in _pe_read_res_dir(data, root_off + ent_off):
            if not (n2 & 0x80000000):
                ids.append(n2)
        return ids
    return []


def extract_exe_ico(exe: Path, ico_path: Path) -> bool:
    """Extract the largest icon group from a PE EXE into a .ico file."""
    data = exe.read_bytes()
    parsed = _pe_parse_sections(data)
    if not parsed:
        return False
    sections, res_rva = parsed
    RT_ICON, RT_GROUP_ICON = 3, 14
    group_ids = _pe_list_ids(data, sections, res_rva, RT_GROUP_ICON)
    if not group_ids:
        return False

    best_ico: bytes | None = None
    best_score = -1
    for gid in group_ids:
        group = _pe_resource_data(data, sections, res_rva, [RT_GROUP_ICON, gid])
        if not group or len(group) < 6:
            continue
        _res, _typ, count = struct.unpack_from("<HHH", group, 0)
        if count == 0 or 6 + count * 14 > len(group):
            continue
        entries = []
        images = []
        score = 0
        for i in range(count):
            w, h, colors, _resv, planes, bitcount, nbytes, icon_id = struct.unpack_from(
                "<BBBBHHIH", group, 6 + i * 14
            )
            width = w or 256
            height = h or 256
            img = _pe_resource_data(data, sections, res_rva, [RT_ICON, icon_id])
            if not img:
                continue
            entries.append((width, height, colors, planes, bitcount, len(img)))
            images.append(img)
            score = max(score, width * height * max(bitcount, 1))
        if not images:
            continue
        # Build ICO: ICONDIR + ICONDIRENTRY[] + image data
        out = bytearray()
        out += struct.pack("<HHH", 0, 1, len(images))
        offset = 6 + 16 * len(images)
        for (width, height, colors, planes, bitcount, nbytes), img in zip(entries, images):
            out += struct.pack(
                "<BBBBHHII",
                0 if width >= 256 else width,
                0 if height >= 256 else height,
                colors,
                0,
                planes,
                bitcount,
                nbytes,
                offset,
            )
            offset += nbytes
        for img in images:
            out += img
        if score > best_score:
            best_score = score
            best_ico = bytes(out)

    if not best_ico:
        return False
    ico_path.write_bytes(best_ico)
    return True


def _ico_best_png(ico_path: Path, work: Path) -> Path | None:
    """If the ICO embeds a PNG (Vista+), write the largest one and return its path."""
    data = ico_path.read_bytes()
    if len(data) < 6:
        return None
    _res, typ, count = struct.unpack_from("<HHH", data, 0)
    if typ != 1 or count < 1:
        return None
    best: bytes | None = None
    best_score = -1
    for i in range(count):
        ent = 6 + i * 16
        if ent + 16 > len(data):
            break
        w, h, _c, _r, _p, _b, nbytes, offset = struct.unpack_from("<BBBBHHII", data, ent)
        if offset + nbytes > len(data):
            continue
        blob = data[offset : offset + nbytes]
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            continue
        score = (w or 256) * (h or 256)
        if score > best_score:
            best_score = score
            best = blob
    if not best:
        return None
    out = work / "icon_src.png"
    out.write_bytes(best)
    return out


def _sips_to_png(src: Path, png: Path) -> bool:
    try:
        subprocess.check_call(
            ["sips", "-s", "format", "png", str(src), "--out", str(png)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return png.is_file()


def exe_to_icns(exe: Path, icns_path: Path) -> bool:
    """Extract EXE icon and convert to AppIcon.icns via sips/iconutil."""
    with tempfile.TemporaryDirectory(prefix="cyder-icon-") as tmp:
        work = Path(tmp)
        ico = work / "app.ico"
        try:
            if not extract_exe_ico(exe, ico):
                return False
        except OSError as e:
            print(f"Warning: could not read EXE icon: {e}", file=sys.stderr)
            return False

        png = work / "icon.png"
        # Prefer embedded PNG, then let sips read the .ico (handles classic DIB icons).
        src = _ico_best_png(ico, work)
        if src is None or not _sips_to_png(src, png):
            if not _sips_to_png(ico, png):
                return False

        iconset = work / "AppIcon.iconset"
        iconset.mkdir()
        # iconutil expects specific filenames.
        sizes = [
            (16, "icon_16x16.png"),
            (32, "diana.p@example.org"),
            (32, "icon_32x32.png"),
            (64, "ivan.p@example.net"),
            (128, "icon_128x128.png"),
            (256, "wendy.h@example.net"),
            (256, "icon_256x256.png"),
            (512, "wendy.h@example.net"),
            (512, "icon_512x512.png"),
            (1024, "walt.e@example.net"),
        ]
        for px, name in sizes:
            out = iconset / name
            try:
                subprocess.check_call(
                    ["sips", "-z", str(px), str(px), str(png), "--out", str(out)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except subprocess.CalledProcessError:
                return False

        try:
            subprocess.check_call(
                ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            return False
    return icns_path.is_file()


def ensure_shared_engine(engine_src: Path) -> Path:
    dest = ENGINES / ENGINE_NAME
    marker = dest / "bin" / "wine"
    if marker.is_file():
        print(f"Shared engine present: {dest}")
        return dest

    print(f"Installing shared engine -> {dest}")
    ENGINES.mkdir(parents=True, exist_ok=True)
    engine_src = engine_src.resolve()
    bundled = engine_src / "lib/wine/x86_64-unix/libfreetype.6.dylib"
    # Bundle only when source still depends on project .brew-x86
    if not bundled.is_file() or bundled.is_symlink():
        bundle_sh = SCRIPTS / "bundle-wine-dylibs.sh"
        if bundle_sh.is_file():
            run(["bash", str(bundle_sh), str(engine_src)])
    if dest.exists():
        shutil.rmtree(dest)
    run(["rsync", "-a", f"{engine_src}/", f"{dest}/"])
    sign_sh = SCRIPTS / "sign-wine.sh"
    env_sh = SCRIPTS / "env-x86_64.sh"
    if sign_sh.is_file():
        if env_sh.is_file():
            run(
                [
                    "bash",
                    "-c",
                    f'source "{env_sh}" && WINE_INSTALL="{dest}" '
                    f'ENTITLEMENTS_PLIST="{ENTITLEMENTS}" '
                    f'bash "{sign_sh}" --root "{dest}"',
                ]
            )
        else:
            run(
                [
                    "bash",
                    str(sign_sh),
                    "--root",
                    str(dest),
                    "--entitlements",
                    str(ENTITLEMENTS),
                ]
            )
    return dest


def wine_locale_env(env: dict[str, str] | None = None) -> dict[str, str]:
    """Match run-bluecg.sh: force zh_TW so Wine uses CP950 (Big5), not Finder's en_US."""
    out = dict(env) if env is not None else os.environ.copy()
    out["LANG"] = "zh_TW.UTF-8"
    out["LC_ALL"] = "zh_TW.UTF-8"
    return out


def init_bottle(wine_bin: Path, bottle: Path) -> None:
    if (bottle / "system.reg").exists():
        print(f"Bottle exists: {bottle}")
        return
    print(f"Creating bottle: {bottle}")
    bottle.mkdir(parents=True, exist_ok=True)
    env = wine_locale_env()
    env["WINEPREFIX"] = str(bottle)
    # Avoid interactive Gecko dialog during bottle init; keep mscoree for .NET launchers.
    env["WINEDLLOVERRIDES"] = "mshtml="
    env["WINESERVER"] = str(wine_bin.parent / "wineserver")
    run(["arch", "-x86_64", str(wine_bin), "wineboot", "-u"], env=env)
    # dosdevices
    dos = bottle / "dosdevices"
    dos.mkdir(exist_ok=True)
    c_link = dos / "c:"
    z_link = dos / "z:"
    if c_link.exists() or c_link.is_symlink():
        c_link.unlink()
    if z_link.exists() or z_link.is_symlink():
        z_link.unlink()
    c_link.symlink_to("../drive_c")
    z_link.symlink_to("/")
    run(["arch", "-x86_64", str(wine_bin.parent / "wineserver"), "-k"], env=env)


def apply_mac_hires(wine_bin: Path, prefix: Path, *, enable: bool = True) -> None:
    """Apply CrossOver-like RetinaMode + LogPixels=192 (+ ClearType RGB). See enable-mac-retina-hires.sh."""
    wineserver = wine_bin.parent / "wineserver"
    env = wine_locale_env()
    env["WINEPREFIX"] = str(prefix.resolve())
    env["WINESERVER"] = str(wineserver)
    subprocess.call(
        ["arch", "-x86_64", str(wineserver), "-k"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if enable:
        entries = [
            (r"HKCU\Software\Wine\Mac Driver", "RetinaMode", "REG_SZ", "y"),
            (r"HKCU\Control Panel\Desktop", "LogPixels", "REG_DWORD", "0xc0"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothing", "REG_SZ", "2"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingType", "REG_DWORD", "2"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingGamma", "REG_DWORD", "0x578"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingOrientation", "REG_DWORD", "1"),
        ]
        label = "ON (RetinaMode=y, DPI=192)"
    else:
        entries = [
            (r"HKCU\Software\Wine\Mac Driver", "RetinaMode", "REG_SZ", "n"),
            (r"HKCU\Control Panel\Desktop", "LogPixels", "REG_DWORD", "0x60"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothing", "REG_SZ", "2"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingType", "REG_DWORD", "1"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingGamma", "REG_DWORD", "0"),
            (r"HKCU\Control Panel\Desktop", "FontSmoothingOrientation", "REG_DWORD", "1"),
        ]
        label = "OFF"
    for key, name, typ, val in entries:
        run(
            [
                "arch",
                "-x86_64",
                str(wine_bin),
                "reg",
                "add",
                key,
                "/v",
                name,
                "/t",
                typ,
                "/d",
                val,
                "/f",
            ],
            env=env,
        )
    subprocess.call(
        ["arch", "-x86_64", str(wineserver), "-k"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"Mac high-res mode {label} -> {prefix}")


def write_game_launcher(path: Path) -> None:
    # Agent-style launcher: start Wine in a new session and exit so the wrapper
    # does not stay in the Dock (bouncing). Wine shows the Windows EXE icon.
    path.write_text(
        """#!/bin/bash
set -euo pipefail
# Force zh_TW like scripts/run-bluecg.sh (Finder often sets en_US → Wine shows ?? for CJK IME).
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
META="$RES/meta.json"

exec python3 - "$META" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

meta = json.loads(Path(sys.argv[1]).read_text())
support = Path.home() / "Library/Application Support/Cyder"
res = Path(sys.argv[1]).resolve().parent

if meta.get("portable_engine"):
    wine_root = res / "wine"
else:
    wine_root = support / "Engines" / meta.get("engine_version", "wine-x86_64")

wine = wine_root / "bin" / "wine"
if not wine.is_file():
    sys.exit(f"Wine engine not found: {wine}\\nRe-open Cyder.app to install the shared engine.")

if meta.get("prefix_mode") == "game_dir":
    prefix = Path(meta["game_dir"])
else:
    prefix = support / "Bottles" / meta["bottle_id"]

if meta.get("standalone"):
    game_dir = res / "game"
    exe = game_dir / meta["exe_name"]
else:
    game_dir = Path(meta["game_dir"])
    exe = Path(meta["exe"])

if not exe.is_file():
    sys.exit(f"Game EXE not found:\\n{exe}")

env = os.environ.copy()
env["WINEPREFIX"] = str(prefix)
env["LANG"] = "zh_TW.UTF-8"
env["LC_ALL"] = "zh_TW.UTF-8"
env["PATH"] = f"{wine_root / 'bin'}:{env.get('PATH', '')}"
env["WINESERVER"] = str(wine_root / "bin" / "wineserver")
if meta.get("msync", True):
    env["WINEMSYNC"] = "1"
if meta.get("no_gecko_prompt"):
    env["WINEDLLOVERRIDES"] = "mshtml=" + ((";" + env["WINEDLLOVERRIDES"]) if env.get("WINEDLLOVERRIDES") else "")

cmd = ["arch", "-x86_64", str(wine), str(exe)]
if meta.get("exe_args"):
    cmd.extend(meta["exe_args"])
# Detach from the .app process group so the wrapper can exit without killing Wine,
# and so Dock only keeps Wine's Windows-app icon (not a bouncing CyderGame).
subprocess.Popen(
    cmd,
    env=env,
    cwd=str(game_dir),
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
sys.exit(0)
PY
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_info_plist(path: Path, name: str, bundle_id: str, *, has_icon: bool = False) -> None:
    icon_keys = ""
    if has_icon:
        icon_keys = """  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
"""
    path.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleExecutable</key>
  <string>CyderGame</string>
  <key>CFBundleIdentifier</key>
  <string>{bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>{name}</string>
{icon_keys}  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
""",
        encoding="utf-8",
    )


def create_game_app(
    exe: Path,
    output_dir: Path,
    *,
    standalone: bool,
    portable_engine: bool,
    prefix_mode: str,
    no_gecko_prompt: bool,
    mac_hires: bool,
    msync: bool,
    engine_src: Path,
) -> Path:
    exe = exe.expanduser().resolve()
    if not exe.is_file() or exe.suffix.lower() != ".exe":
        sys.exit(f"Not an EXE: {exe}")

    game_dir = exe.parent
    app_name = slugify(exe.stem)
    app = output_dir / f"{exe.stem}.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    res = contents / "Resources"
    bottle_id = f"{app_name}-{uuid.uuid4().hex[:8]}"

    if app.exists():
        shutil.rmtree(app)
    macos.mkdir(parents=True)
    res.mkdir(parents=True)

    engine_path = ensure_shared_engine(engine_src)
    wine_bin = engine_path / "bin" / "wine"

    if portable_engine:
        print("Copying portable engine into app...")
        run(["rsync", "-a", f"{engine_path}/", f"{res / 'wine'}/"])

    if standalone:
        print("Copying game files into app (standalone)...")
        dest_game = res / "game"
        run(["rsync", "-a", f"{game_dir}/", f"{dest_game}/"])
        meta_exe = str(dest_game / exe.name)
        meta_game_dir = str(dest_game)
        effective_game_dir = dest_game
    else:
        meta_exe = str(exe)
        meta_game_dir = str(game_dir)
        effective_game_dir = game_dir

    if prefix_mode == "bottle":
        bottle = BOTTLES / bottle_id
        init_bottle(wine_bin, bottle)
        effective_prefix = bottle
    elif prefix_mode == "game_dir":
        bottle_id = ""
        effective_prefix = effective_game_dir
        # use game directory as prefix; ensure minimal wine files if missing
        if not (effective_game_dir / "system.reg").exists():
            print("Initializing game_dir as WINEPREFIX...")
            init_bottle(wine_bin, effective_game_dir)
    else:
        sys.exit(f"Unknown prefix_mode: {prefix_mode}")

    if mac_hires:
        apply_mac_hires(wine_bin, effective_prefix, enable=True)

    meta = {
        "name": exe.stem,
        "exe": meta_exe,
        "exe_name": exe.name,
        "game_dir": meta_game_dir,
        "engine_version": ENGINE_NAME,
        "portable_engine": portable_engine,
        "standalone": standalone,
        "prefix_mode": prefix_mode,
        "bottle_id": bottle_id,
        "no_gecko_prompt": no_gecko_prompt,
        "mac_hires": mac_hires,
        "msync": msync,
        "exe_args": [],
    }
    (res / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if ENTITLEMENTS.is_file():
        shutil.copy2(ENTITLEMENTS, res / "entitlements.plist")

    write_game_launcher(macos / "CyderGame")

    icns = res / "AppIcon.icns"
    has_icon = exe_to_icns(exe, icns)
    if has_icon:
        print(f"App icon: {icns.name} (from {exe.name})")
    else:
        print(f"Warning: no icon found in {exe.name}; using default app icon", file=sys.stderr)

    write_info_plist(
        contents / "Info.plist",
        exe.stem,
        f"local.cyder.game.{app_name}",
        has_icon=has_icon,
    )

    # Ad-hoc sign launcher (+ icon resources)
    subprocess.call(["codesign", "--force", "--deep", "--sign", "-", str(app)])

    print(f"\nCreated: {app}")
    print(
        f"  mode: link={'no' if standalone else 'yes'}  portable_engine={portable_engine}  "
        f"prefix={prefix_mode}  mac_hires={mac_hires}  msync={msync}"
    )
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="Cyder: wrap a Windows EXE as a macOS app")
    parser.add_argument("--gui", action="store_true", help="Pick EXE via macOS dialogs")
    parser.add_argument("--exe", type=Path, help="Path to Windows EXE")
    parser.add_argument("--output", type=Path, default=Path.home() / "Desktop", help="Output directory for .app")
    parser.add_argument("--standalone", action="store_true", help="Copy game files into the app")
    parser.add_argument("--portable-engine", action="store_true", help="Embed Wine engine in the app")
    parser.add_argument(
        "--prefix-mode",
        choices=("bottle", "game_dir"),
        default="bottle",
        help="bottle=clean prefix in Application Support; game_dir=use game folder as WINEPREFIX",
    )
    parser.add_argument("--no-gecko-prompt", action="store_true", help="Disable mshtml for this game")
    parser.add_argument(
        "--no-mac-hires",
        action="store_true",
        help="Do not enable Mac RetinaMode + 200%% DPI in the prefix",
    )
    parser.add_argument(
        "--no-msync",
        action="store_true",
        help="Do not set WINEMSYNC=1 (Wine sync performance on macOS)",
    )
    parser.add_argument("--engine-src", type=Path, default=DEFAULT_ENGINE_SRC)
    args = parser.parse_args()

    if args.gui or args.exe is None:
        exe = choose_exe()
        output = choose_output_dir(args.output)
        standalone = ask_yes_no("複製遊戲檔進 App？（Standalone，預設否＝連結原路徑）", default_no=True)
        portable = ask_yes_no("內嵌完整 Wine 引擎？（可攜包，預設否＝使用共用引擎）", default_no=True)
        game_dir_prefix = ask_yes_no(
            "進階：把遊戲目錄當作 Wine prefix？（BlueCG 模式，預設否＝獨立 bottle）",
            default_no=True,
        )
        prefix_mode = "game_dir" if game_dir_prefix else "bottle"
        no_gecko = ask_yes_no("停用 mshtml 以避免 Gecko 安裝提示？（預設否）", default_no=True)
        mac_hires = ask_yes_no(
            "啟用 Mac 高解析度模式？（RetinaMode + 200% DPI，建議 Retina 螢幕）",
            default_no=False,
        )
        msync = True  # WINEMSYNC=1 by default; CLI: --no-msync to disable
    else:
        exe = args.exe
        output = args.output
        standalone = args.standalone
        portable = args.portable_engine
        prefix_mode = args.prefix_mode
        no_gecko = args.no_gecko_prompt
        mac_hires = not args.no_mac_hires
        msync = not args.no_msync

    if not args.engine_src.is_dir():
        sys.exit(f"Engine source not found: {args.engine_src}\nBuild wine first.")

    app = create_game_app(
        exe,
        output,
        standalone=standalone,
        portable_engine=portable,
        prefix_mode=prefix_mode,
        no_gecko_prompt=no_gecko,
        mac_hires=mac_hires,
        msync=msync,
        engine_src=args.engine_src,
    )
    # Reveal in Finder when GUI
    if args.gui or args.exe is None:
        subprocess.call(["open", "-R", str(app)])


if __name__ == "__main__":
    main()
