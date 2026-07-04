#!/usr/bin/env python3
"""Create a macOS .app that launches a Windows EXE via Cyder's Wine engine."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
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


def init_bottle(wine_bin: Path, bottle: Path) -> None:
    if (bottle / "system.reg").exists():
        print(f"Bottle exists: {bottle}")
        return
    print(f"Creating bottle: {bottle}")
    bottle.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
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


def write_game_launcher(path: Path) -> None:
    path.write_text(
        """#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
META="$RES/meta.json"

python3 - "$META" <<'PY'
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
env["LANG"] = env.get("LANG", "zh_TW.UTF-8")
env["PATH"] = f"{wine_root / 'bin'}:{env.get('PATH', '')}"
if meta.get("no_gecko_prompt"):
    env["WINEDLLOVERRIDES"] = "mshtml=" + ((";" + env["WINEDLLOVERRIDES"]) if env.get("WINEDLLOVERRIDES") else "")

os.chdir(game_dir)
cmd = ["arch", "-x86_64", str(wine), str(exe)]
if meta.get("exe_args"):
    cmd.extend(meta["exe_args"])
os.execvpe(cmd[0], cmd, env)
PY
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_info_plist(path: Path, name: str, bundle_id: str) -> None:
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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
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
    elif prefix_mode == "game_dir":
        bottle_id = ""
        # use game directory as prefix; ensure minimal wine files if missing
        if not (effective_game_dir / "system.reg").exists():
            print("Initializing game_dir as WINEPREFIX...")
            init_bottle(wine_bin, effective_game_dir)
    else:
        sys.exit(f"Unknown prefix_mode: {prefix_mode}")

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
        "exe_args": [],
    }
    (res / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if ENTITLEMENTS.is_file():
        shutil.copy2(ENTITLEMENTS, res / "entitlements.plist")

    write_game_launcher(macos / "CyderGame")
    write_info_plist(contents / "Info.plist", exe.stem, f"local.cyder.game.{app_name}")

    # Ad-hoc sign launcher
    subprocess.call(["codesign", "--force", "--sign", "-", str(macos / "CyderGame")])

    print(f"\nCreated: {app}")
    print(f"  mode: link={'no' if standalone else 'yes'}  portable_engine={portable_engine}  prefix={prefix_mode}")
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
    else:
        exe = args.exe
        output = args.output
        standalone = args.standalone
        portable = args.portable_engine
        prefix_mode = args.prefix_mode
        no_gecko = args.no_gecko_prompt

    if not args.engine_src.is_dir():
        sys.exit(f"Engine source not found: {args.engine_src}\nBuild wine first.")

    app = create_game_app(
        exe,
        output,
        standalone=standalone,
        portable_engine=portable,
        prefix_mode=prefix_mode,
        no_gecko_prompt=no_gecko,
        engine_src=args.engine_src,
    )
    # Reveal in Finder when GUI
    if args.gui or args.exe is None:
        subprocess.call(["open", "-R", str(app)])


if __name__ == "__main__":
    main()
