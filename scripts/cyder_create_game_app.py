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

from cyder_common import (
    BOTTLES,
    DEFAULT_ENGINE_SRC,
    ENGINE_NAME,
    ENTITLEMENTS,
    MAC_HIRES_REG_ON,
    OGOM,
    SCRIPTS,
    apply_mac_hires,
    choose_exe,
    ensure_shared_engine,
    init_bottle,
    osascript,
    resolve_wine_locale,
    run,
    wine_locale_env,
)


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
    return extract_exe_ico_data(exe.read_bytes(), ico_path)


def extract_exe_ico_data(data: bytes, ico_path: Path) -> bool:
    """Extract the largest icon group from PE bytes into a .ico file."""
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
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
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


def exe_data_to_png(data: bytes, png_path: Path, size: int = 256) -> bool:
    """Convert the best icon from PE bytes to a game-library PNG."""
    with tempfile.TemporaryDirectory(prefix="cyder-library-icon-") as tmp:
        work = Path(tmp)
        ico = work / "app.ico"
        try:
            if not extract_exe_ico_data(data, ico):
                return False
        except OSError as e:
            print(f"Warning: could not read EXE icon: {e}", file=sys.stderr)
            return False

        source = _ico_best_png(ico, work) or ico
        converted = work / "icon.png"
        if not _sips_to_png(source, converted):
            return False

        png_path.parent.mkdir(parents=True, exist_ok=True)
        staged = png_path.with_name(f".{png_path.name}.{os.getpid()}.tmp.png")
        try:
            subprocess.check_call(
                ["sips", "-z", str(size), str(size), str(converted), "--out", str(staged)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            staged.replace(png_path)
        except (subprocess.CalledProcessError, OSError):
            staged.unlink(missing_ok=True)
            return False
    return png_path.is_file()


def exe_to_png(exe: Path, png_path: Path, size: int = 256) -> bool:
    """Extract the best PE icon as a PNG suitable for the native game library."""
    try:
        return exe_data_to_png(exe.read_bytes(), png_path, size=size)
    except OSError as e:
        print(f"Warning: could not read EXE icon: {e}", file=sys.stderr)
        return False


def write_game_launcher(path: Path) -> None:
    # Agent-style launcher: start Wine in a new session and exit so the wrapper
    # does not stay in the Dock (bouncing). Wine shows the Windows EXE icon.
    path.write_text(
        """#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
META="$RES/meta.json"

exec python3 - "$META" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

def resolve_wine_locale():
    fallback = os.environ.get("CYDER_WINE_LOCALE_FALLBACK", "zh_TW.UTF-8")
    def valid(val):
        return bool(val) and val not in ("C", "POSIX", "C.UTF-8")
    lc_all = os.environ.get("LC_ALL", "").strip()
    if valid(lc_all):
        return lc_all
    try:
        apple = subprocess.check_output(
            ["defaults", "read", "-g", "AppleLocale"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        apple = ""
    apple_map = {
        "zh-Hant_TW": "zh_TW.UTF-8",
        "zh_TW": "zh_TW.UTF-8",
        "zh-Hant_HK": "zh_HK.UTF-8",
        "zh_HK": "zh_HK.UTF-8",
        "zh-Hans_CN": "zh_CN.UTF-8",
        "zh-Hant_CN": "zh_CN.UTF-8",
        "zh_CN": "zh_CN.UTF-8",
        "ja_JP": "ja_JP.UTF-8",
        "ja": "ja_JP.UTF-8",
        "ko_KR": "ko_KR.UTF-8",
        "ko": "ko_KR.UTF-8",
    }
    if apple in apple_map:
        return apple_map[apple]
    if apple.startswith("en"):
        return "en_US.UTF-8"
    if apple:
        return apple.replace("-", "_") + ("" if "." in apple else ".UTF-8")
    lang = os.environ.get("LANG", "").strip()
    if valid(lang):
        return lang
    return fallback

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
loc = resolve_wine_locale()
env["LANG"] = loc
env["LC_ALL"] = loc
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
    parser.add_argument(
        "--extract-icon",
        nargs=2,
        metavar=("EXE", "PNG"),
        help="Extract an EXE icon to a PNG for Cyder's game library",
    )
    parser.add_argument(
        "--extract-icon-stdin",
        type=Path,
        metavar="PNG",
        help="Read PE bytes from stdin and extract an icon without reopening the EXE",
    )
    args = parser.parse_args()

    if args.extract_icon_stdin:
        if not exe_data_to_png(sys.stdin.buffer.read(), args.extract_icon_stdin.expanduser(), size=256):
            sys.exit(2)
        return

    if args.extract_icon:
        exe, png = map(Path, args.extract_icon)
        if not exe_to_png(exe.expanduser().resolve(), png.expanduser(), size=256):
            sys.exit(2)
        return

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
