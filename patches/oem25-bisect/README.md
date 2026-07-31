# OEM CX25 reverse-removal groups (G/W/L/P/S)

Used with `scripts/prepare-maplestory-oem25-reverse-group.sh` to reverse one
patch group from a working OEM CX25 Wine tree toward retail CX25.0.1, then rebuild
and A/B with `scripts/run-maplestory-cx25-source-ab.sh`.

Trees:

- OEM: `build/maplestory-oem25/sources/wine`
- Retail: `build/cx25/sources/wine` (CX25.0.1)

Each `group-*.files` lists paths safe for **whole-file** replace with retail.
Mixed files (multiple groups in one file) are listed in `group-*.mixed` and must
be reversed by hunk, not by copying the entire retail file.

Order used: **S → P → W → L → G** (2026-07-23).

### Results

| Round | Engine | No-OTP surface | OTP / in-world |
|---|---|---|---|
| Baseline | `dist/wine-maplestory-oem25-source-x86_64` + OEM MoltenVK | pass | pass with **`C:\MapleTest`** (Documents `Z:` →「檔案損毀」) |
| rev-S | `…-rev-S-x86_64` | pass | — |
| rev-P | `…-rev-P-x86_64` | **fail** (retail dbghelp) | — |
| rev-Pfc | `…-rev-Pfc-x86_64` | pass (keep OEM dbghelp) | — |
| rev-W | `…-rev-W-x86_64` | pass | — |
| rev-L | `…-rev-L-x86_64` | **fail** (retail kernelbase) | — |
| rev-Lgs | `…-rev-Lgs-x86_64` | pass (keep OEM kernelbase) | login OK; enter-world not isolated (path／disk confounded) |
| rev-G | `…-rev-G-x86_64` | pass | **enters world** but broken visuals (no cursor, black map, missing UI／eyes); massive `ClearView` stubs |

### Necessary sets

**No-OTP title／login:**

1. OEM binary MoltenVK
2. OEM dbghelp
3. OEM kernelbase `.dll`→`.tmp`／`.msf`

**OTP／in-world (complete visuals):**

1–3 above, plus **whole group G** (ClearView／shared texture／wined3d state — do not split),
and launch from **`C:\MapleTest`** (APFS clone into bottle `drive_c`), not Documents `Z:`
on self-built source Wine.

Not required: **S**, **P file-cache／no-yield**, **W**, **L gstreamer／`rawaudioparse`**.

### CX26 mapping

See [`docs/games/maplestory/oem-cx25-maplestory-patches.md`](../../docs/games/maplestory/oem-cx25-maplestory-patches.md) §11.2.
Build with `scripts/build-wine.sh --cx 26 --maplestory-shared-texture-test` and re-copy OEM
`libMoltenVK.dylib` after bundle／install.

### Incremental rebuild tip

Clone a tree that still has `build64`, reverse files, `rm` affected `.o`／libs, `make`
targets, seed install from parent, overwrite libs, re-copy OEM MoltenVK.
