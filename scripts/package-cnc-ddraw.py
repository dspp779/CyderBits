#!/usr/bin/env python3
"""Create Cyder's offline runtime subset from the pinned official release ZIP."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile

SOURCE_SHA = "0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908"
FILES = {
    "ddraw.dll": "85e0f7d530dfda134793a57cb3e76b0287dcc96892ee57162dd68f47283b03a9",
    "ddraw.ini": "2571322a64a767022627ed076f9539179eff322efa336016e8af1f2337cc8fcb",
    "Shaders/interpolation/catmull-rom-bilinear.glsl": "18e89f829f4c82d5b1e0d1fa9b41d6698cf3fbd2d45ef8abb9f6d7a2452c9426",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def package(source, destination):
    archive = source / "cnc-ddraw.zip"
    if digest(archive.read_bytes()) != SOURCE_SHA:
        raise ValueError("Unexpected upstream cnc-ddraw archive")
    manifest = json.loads((source / "manifest.json").read_text())
    out = destination / archive.name
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as official, zipfile.ZipFile(out, "x") as subset:
        for name, expected in FILES.items():
            data = official.read(name)
            if digest(data) != expected:
                raise ValueError(f"Unexpected upstream file: {name}")
            # Use stored entries, fixed metadata and stable ordering across zlib versions.
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            subset.writestr(info, data)
    for name in ["LICENSE", "THIRD-PARTY-NOTICES.txt"]:
        shutil.copyfile(source / name, destination / name)
    manifest.update(archiveRole="runtime-subset", upstreamArchiveSha256=SOURCE_SHA,
                    archiveSha256=digest(out.read_bytes()), bundledFiles=FILES)
    manifest["install"] = {"destination": "per_game", "include": list(FILES)}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    package(Path(sys.argv[1]), Path(sys.argv[2]))
