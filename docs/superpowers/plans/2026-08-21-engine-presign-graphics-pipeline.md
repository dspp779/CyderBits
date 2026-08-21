# Engine presign skip + graphics payload∥wineboot — Implementation Plan

**Goal:** Skip redundant engine resign on install; overlap DXVK/DXMT unpack with wineboot; time graphics stages.

**Files:** `cyder-common.sh`, `pack-engine-artifact.sh`, `cyder-ensure-graphics.sh`, tests.

**Verify:** `bash tests/test-cyder-bootstrap-timing.sh && bash tests/test-cyder-engine-presign-skip.sh`
