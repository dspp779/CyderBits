# cnc-ddraw vendored runtime

Cyder vendors the official `cnc-ddraw.zip` release for deterministic,
offline per-game provisioning. The archive is not executed by the installer;
only `ddraw.dll`, `ddraw.ini`, and `Shaders/` are extracted beside an explicitly
selected game executable.

The version, upstream URL, SHA-256, license, and extraction allowlist are pinned
in each version directory's `manifest.json`. `cnc-ddraw config.exe` is
intentionally not installed.

Upstream: <https://github.com/FunkyFr3sh/cnc-ddraw>

License: MIT (see the versioned `LICENSE` file).
