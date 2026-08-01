#!/usr/bin/env python3
"""Pin DXVK's meson version.h generation to sources/RELEASE.

CrossOver FOSS tarballs ship dxvk without a nested .git. Meson's vcs_tag runs
`git describe`, which walks up into the Cyder app repo and bakes the wrong
string (e.g. v0.7.0-25-g...) into dxgi/d3d11 logs. Replace vcs_tag with a
configure_file that uses RELEASE (pure upstream version, e.g. v1.10.3).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

VCS_TAG_RE = re.compile(
    r"dxvk_version\s*=\s*vcs_tag\s*\(\s*"
    r"command\s*:\s*\[[^\]]+\]\s*,\s*"
    r"input\s*:\s*'version\.h\.in'\s*,\s*"
    r"output\s*:\s*'version\.h'\s*,?\s*"
    r"\)",
    re.MULTILINE,
)

CONFIGURE_FILE_RE = re.compile(
    r"dxvk_version\s*=\s*configure_file\s*\(",
    re.MULTILINE,
)


def release_to_version(release: str) -> str:
    release = release.strip()
    if not release:
        raise ValueError("RELEASE is empty")
    return release if release.startswith("v") else f"v{release}"


def pin_meson_build(meson_text: str, version: str) -> tuple[str, bool]:
    """Return (new_text, changed)."""
    replacement = (
        f"# Cyder: pin to RELEASE — CX tarball has no dxvk .git.\n"
        f"_dxvk_version_conf = configuration_data()\n"
        f"_dxvk_version_conf.set('VCS_TAG', '{version}')\n"
        f"dxvk_version = configure_file(\n"
        f"  configuration: _dxvk_version_conf,\n"
        f"  input: 'version.h.in',\n"
        f"  output: 'version.h',\n"
        f")\n"
    )

    if VCS_TAG_RE.search(meson_text):
        return VCS_TAG_RE.sub(replacement.rstrip("\n"), meson_text, count=1), True

    if CONFIGURE_FILE_RE.search(meson_text) and f"'{version}'" in meson_text:
        return meson_text, False

    if CONFIGURE_FILE_RE.search(meson_text):
        # Already pinned to a different string — rewrite the set() line.
        updated, n = re.subn(
            r"_dxvk_version_conf\.set\('VCS_TAG',\s*'[^']*'\)",
            f"_dxvk_version_conf.set('VCS_TAG', '{version}')",
            meson_text,
            count=1,
        )
        if n:
            return updated, True

    raise ValueError("meson.build: expected dxvk_version = vcs_tag(...) or Cyder configure_file pin")


def pin_dxvk_source(source: Path) -> str:
    release_path = source / "RELEASE"
    meson_path = source / "meson.build"
    if not release_path.is_file():
        raise FileNotFoundError(f"missing {release_path}")
    if not meson_path.is_file():
        raise FileNotFoundError(f"missing {meson_path}")

    version = release_to_version(release_path.read_text(encoding="utf-8"))
    text = meson_path.read_text(encoding="utf-8")
    new_text, changed = pin_meson_build(text, version)
    if changed:
        meson_path.write_text(new_text, encoding="utf-8")
    return version


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Path to extracted sources/dxvk")
    args = parser.parse_args(argv)
    try:
        version = pin_dxvk_source(args.source.resolve())
    except (OSError, ValueError) as exc:
        print(f"pin-dxvk-version: {exc}", file=sys.stderr)
        return 1
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
