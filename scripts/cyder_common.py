"""Shared helpers for Cyder launcher and CyderBits packager."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

# When launched from Cyder.app, Resources/ is OGOM-like and scripts live in ogom-scripts/.
_HERE = Path(__file__).resolve().parent


def _read_engine_version(resources: Path) -> str | None:
    ver_file = resources / "engine-version.txt"
    if not ver_file.is_file():
        return None
    ver = ver_file.read_text(encoding="utf-8").strip()
    return ver or None


def _engine_tarball_path(resources: Path) -> Path | None:
    ver = _read_engine_version(resources)
    if not ver:
        return None
    for name in (f"engine-{ver}.tar.zst", f"engine-wine-x86_64-{ver}.tar.xz"):
        candidate = resources / name
        if candidate.is_file():
            return candidate
    return None


def _default_engine_src(here: Path) -> Path:
    tarball = _engine_tarball_path(here)
    if tarball is not None:
        return tarball
    if (here / "engine-payload").is_dir():
        return here / "engine-payload"
    return here.parent / "install" / "wine-cx26-x86_64"


# When launched from Cyder.app, Resources/ is OGOM-like and scripts live in ogom-scripts/.
if _engine_tarball_path(_HERE) is not None or (_HERE / "engine-payload").is_dir():
    OGOM = _HERE
    SCRIPTS = Path(os.environ.get("CYDER_SCRIPTS", _HERE / "ogom-scripts"))
    DEFAULT_ENGINE_SRC = Path(os.environ.get("CYDER_ENGINE_SRC", _default_engine_src(_HERE)))
    ENTITLEMENTS = _HERE / "entitlements.plist"
else:
    OGOM = _HERE.parent
    SCRIPTS = Path(os.environ.get("CYDER_SCRIPTS", OGOM / "scripts"))
    DEFAULT_ENGINE_SRC = Path(os.environ.get("CYDER_ENGINE_SRC", OGOM / "install" / "wine-cx26-x86_64"))
    ENTITLEMENTS = OGOM / "config" / "entitlements.plist"

SUPPORT = Path.home() / "Library" / "Application Support" / "Cyder"
ENGINES = SUPPORT / "Engines"
BOTTLES = SUPPORT / "Bottles"
# CYDER_SHARED_PREFIX overrides SHARED_PREFIX for isolated bootstrap tests only.
_shared_prefix_override = os.environ.get("CYDER_SHARED_PREFIX")
SHARED_PREFIX = (
    Path(_shared_prefix_override) if _shared_prefix_override else SUPPORT / "SharedPrefix"
)
ADDONS = SUPPORT / "Addons"
ENGINE_NAME = "wine-x86_64"
BOOTSTRAP_MARKER = SHARED_PREFIX / ".cyder-bootstrap-v1"
LIBARCHIVE_ADDON = ADDONS / "libarchive-2.4.12"

MAC_HIRES_REG_ON = [
    (r"HKCU\Software\Wine\Mac Driver", "RetinaMode", "REG_SZ", "y"),
    (r"HKCU\Control Panel\Desktop", "LogPixels", "REG_DWORD", "0xc0"),
    (r"HKCU\Control Panel\Desktop", "FontSmoothing", "REG_SZ", "2"),
    (r"HKCU\Control Panel\Desktop", "FontSmoothingType", "REG_DWORD", "2"),
    (r"HKCU\Control Panel\Desktop", "FontSmoothingGamma", "REG_DWORD", "0x578"),
    (r"HKCU\Control Panel\Desktop", "FontSmoothingOrientation", "REG_DWORD", "1"),
]


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


def resolve_wine_locale() -> str:
    """Prefer explicit env, then macOS AppleLocale, then LANG; fallback zh_TW.UTF-8."""
    fallback = os.environ.get("CYDER_WINE_LOCALE_FALLBACK", "zh_TW.UTF-8")

    def valid(val: str) -> bool:
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
        if "." in apple:
            return apple.replace("-", "_")
        return f"{apple.replace('-', '_')}.UTF-8"

    lang = os.environ.get("LANG", "").strip()
    if valid(lang):
        return lang

    return fallback


def wine_locale_env(env: dict[str, str] | None = None) -> dict[str, str]:
    out = dict(env) if env is not None else os.environ.copy()
    loc = resolve_wine_locale()
    out["LANG"] = loc
    out["LC_ALL"] = loc
    return out


def _engine_version_from_archive(path: Path) -> str:
    name = path.name
    for suffix in (".tar.zst", ".tar.xz"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    if name.startswith("engine-"):
        name = name[len("engine-") :]
    if name.startswith("wine-x86_64-"):
        name = name[len("wine-x86_64-") :]
    return name


def _tarball_has_wine_root(path: Path) -> bool:
    out = subprocess.check_output(["tar", "-tf", str(path)], text=True, stderr=subprocess.DEVNULL)
    first = out.splitlines()[0] if out else ""
    return first.startswith("wine-x86_64/")


def ensure_shared_engine(engine_src: Path) -> Path:
    dest = ENGINES / ENGINE_NAME
    marker = dest / "bin" / "wine"
    version_marker = dest / ".cyder-engine-version"
    engine_src = engine_src.resolve()
    bundled_version = ""
    if engine_src.name.endswith((".tar.zst", ".tar.xz")):
        bundled_version = _engine_version_from_archive(engine_src)
    installed_version = ""
    if version_marker.is_file():
        installed_version = version_marker.read_text(encoding="utf-8").strip()

    if marker.is_file():
        if not bundled_version or installed_version == bundled_version:
            print(f"Shared engine present: {dest}")
            return dest
        print(f"Upgrading shared engine ({installed_version} -> {bundled_version}) -> {dest}")

    print(f"Installing shared engine -> {dest}")
    ENGINES.mkdir(parents=True, exist_ok=True)

    if engine_src.name.endswith(".tar.xz"):
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True, exist_ok=True)
        run(["tar", "-xJf", str(engine_src), "-C", str(dest)])
    elif engine_src.name.endswith(".tar.zst"):
        if dest.exists():
            shutil.rmtree(dest)
        if _tarball_has_wine_root(engine_src):
            run(["tar", "-xf", str(engine_src), "-C", str(ENGINES)])
        else:
            dest.mkdir(parents=True, exist_ok=True)
            run(["tar", "-xf", str(engine_src), "-C", str(dest)])
    else:
        bundled = engine_src / "lib/wine/x86_64-unix/libfreetype.6.dylib"
        if not bundled.is_file() or bundled.is_symlink():
            bundle_sh = SCRIPTS / "bundle-wine-dylibs.sh"
            if bundle_sh.is_file():
                run(["bash", str(bundle_sh), str(engine_src)])
        if dest.exists():
            shutil.rmtree(dest)
        run(["rsync", "-a", f"{engine_src}/", f"{dest}/"])

    if not marker.is_file():
        raise RuntimeError(f"Engine extract failed: missing {marker}")

    if bundled_version:
        version_marker.write_text(f"{bundled_version}\n", encoding="utf-8")

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
        entries = MAC_HIRES_REG_ON
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


def ensure_shared_prefix(wine_bin: Path) -> Path:
    prefix = SHARED_PREFIX
    if not (prefix / "system.reg").is_file():
        init_bottle(wine_bin, prefix)
    return prefix


def bootstrap_shared_prefix(wine_bin: Path, *, engine_src: Path) -> None:
    prefix = ensure_shared_prefix(wine_bin)
    if BOOTSTRAP_MARKER.is_file():
        return
    mono_sh = SCRIPTS / "install-wine-mono.sh"
    if mono_sh.is_file():
        env = os.environ.copy()
        env["WINEPREFIX"] = str(prefix)
        env["WINE_INSTALL"] = str(wine_bin.parent.parent)
        env["CYDER_DOWNLOADS"] = str(SUPPORT / "downloads")
        subprocess.check_call(["bash", str(mono_sh)], env=env)
    tar_sh = SCRIPTS / "install-libarchive-tar.sh"
    if tar_sh.is_file():
        subprocess.check_call(
            ["bash", str(tar_sh), "--prefix", str(prefix)],
            env={**os.environ, "WINE_INSTALL": str(wine_bin.parent.parent)},
        )
    apply_mac_hires(wine_bin, prefix, enable=True)
    BOOTSTRAP_MARKER.write_text("ok\n", encoding="utf-8")


def run_wine_exe(wine_bin: Path, exe: Path, *, prefix: Path) -> None:
    env = wine_locale_env()
    env["WINEPREFIX"] = str(prefix)
    env["WINESERVER"] = str(wine_bin.parent / "wineserver")
    env["WINEMSYNC"] = "1"
    env["WINEDLLOVERRIDES"] = "mshtml="
    env["PATH"] = f"{wine_bin.parent}:{env.get('PATH', '')}"
    loc = resolve_wine_locale()
    env["LANG"] = loc
    env["LC_ALL"] = loc
    log_dir = SUPPORT / "Logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "last-launch.log"
    cmd = ["arch", "-x86_64", str(wine_bin), str(exe)]
    with open(log_file, "w", encoding="utf-8") as log:
        log.write(f"cmd={' '.join(cmd)}\nWINEPREFIX={prefix}\ncwd={exe.parent}\n\n")
        log.flush()
        subprocess.Popen(
            cmd,
            env=env,
            cwd=str(exe.parent),
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
