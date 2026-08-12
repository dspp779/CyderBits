# Upstream PR dossiers

這個目錄把 `patches/` 內的每個 patch 整理成一份可拿去上游討論的 PR dossier。正文使用英文，方便改寫成 Wine mailing-list 貼文；本索引用繁中說明目前證據、風險與提交順序。

這些文件不是在宣稱所有 patch 都已經符合 Wine upstream 的接受標準。每一份都刻意區分：

- **complete fix**：修正的是可一般化的語意或生命週期錯誤；仍需要 upstream regression test。
- **defensive fix**：補足已知錯誤輸入或失效 metadata 的安全邊界；不一定能修正產生錯誤資料的根因。
- **workaround**：改變 codegen、時序、遊戲特例或私有協定以避開症狀；不應包裝成一般語意修正。
- **diagnostic / migration only**：用來定位問題或遷移舊 build tree，不應作為 runtime PR。

## 建議提交順序

| 類別 | Patch | 建議處理 | 影響嚴重性 |
|---|---|---|---|
| x86_64 unwind | [`wine-11.1-rtlwalkframechain-null-function.md`](wine-11.1-rtlwalkframechain-null-function.md) | 優先送 upstream；最小、一般化 | High：可能造成例外遞迴或 stack overflow |
| x86_64 unwind | [`cyder-ntdll-frame-walk-page-fault.md`](cyder-ntdll-frame-walk-page-fault.md) | 另案討論，先補 regression test | High：malformed unwind data 可崩潰 caller |
| winemac GL | [`a6-r3-same-view-in-place-backing.md`](a6-r3-same-view-in-place-backing.md) + [`a6-r5-restore-rect-authority.md`](a6-r5-restore-rect-authority.md) | 以現行 final 行為重寫成一般化 PR | High：resize 後 black window；目前只在 BlueCG 完整驗證 |
| winemac GL 歷史 | [`a6-r1-live-resize-deferred-backing.md`](a6-r1-live-resize-deferred-backing.md)、[`a6-r2-final-in-place-backing.md`](a6-r2-final-in-place-backing.md)、[`a6-r4-deminiaturize-frame-guard.md`](a6-r4-deminiaturize-frame-guard.md) | 作為設計演進與負面結果，勿逐個提交 | High / Medium |
| D3D11 clear | [`maplestory-d3d11-full-clear.md`](maplestory-d3d11-full-clear.md) | 拆成 API、WineD3D、GL/Vulkan backend 與 tests 多個 commit | High：ClearView 可造成缺圖或錯誤 resource state |
| D3D shared resource | [`maplestory-d3d11-shared-texture-test.md`](maplestory-d3d11-shared-texture-test.md)、[`maplestory-dxgi-shared-handle.md`](maplestory-dxgi-shared-handle.md) | 先確認 Windows semantics；目前是私有 DwarfAxe protocol workaround | High in target game；upstream generality unproven |
| texture memory | [`maplestory-texture-user-memory-reload.md`](maplestory-texture-user-memory-reload.md) | 重新設計 dirty/location tracking 後再送 | Medium/High；現行版本可能每次使用都付效能成本 |
| dbghelp | [`maplestory-dbghelp-dwarf-guard.md`](maplestory-dbghelp-dwarf-guard.md) | 可作窄幅 robustness PR；需最小 DWARF test | Medium：debugger path 可帶崩 crash reporter |
| loader identity | [`maplestory-tmp-module-name.md`](maplestory-tmp-module-name.md) | 先轉成 loader/module identity RFC；現行 sidecar 是 workaround | High for BlackCipher；general semantics unproven |
| winemac app focus | [`maplestory-blackxchg-foreground.md`](maplestory-blackxchg-foreground.md) | 不直接 upstream；改提 generic activation ownership fix | Medium：helper 會偷走前景焦點 |
| win32u restore | [`maplestory-fullscreen-restore.md`](maplestory-fullscreen-restore.md) | 不直接 upstream；移除遊戲 class、magic style/timer 後再議 | Medium/High：fullscreen state 可能被錯誤覆寫 |
| GStreamer | 見 [`maplestory-core-split.md`](maplestory-core-split.md) | 從混合 patch 拆成獨立 raw PCM parser proposal | Medium；目前以環境變數啟用 |
| scheduler | [`maplestory-no-sched-yield.md`](maplestory-no-sched-yield.md) | 暫不送；需要跨遊戲 benchmark | Low/Medium；全域改變 NtYieldExecution |
| build fallback | [`win32u-vulkan-soname-fallback.md`](win32u-vulkan-soname-fallback.md) | 先修 configure/build contract，不建議只加 runtime fallback | Low/Medium：把缺 dependency 延後到 runtime |
| source packaging | [`maplestory-oem25-distversion.md`](maplestory-oem25-distversion.md) | 不送 Wine runtime upstream | Low；OEM source packaging workaround |
| mixed OEM patch | [`maplestory-core-split.md`](maplestory-core-split.md) | 不以原檔案單一 PR 提交，必須拆題 | Mixed |
| old migration patch | [`obsolete-frame-walk-guard.md`](obsolete-frame-walk-guard.md) | 不提交；只保留 migration note | N/A |

## 共通重現規則

MapleStory 重現命令中的登入參數一律使用 placeholder；不要把 OTP、帳號識別碼、token 或完整本機路徑寫進 PR、log 或 commit。可用的專案入口包括：

```sh
scripts/run-bluecg.sh --direct
scripts/run-maplestory-classic-debug.sh <arg1> <session-token> <arg3> <arg4>
bash tests/test-ntdll-frame-walk-guard.sh
bash tests/test-ntdll-frame-walk-patches.sh
```

所有真實遊戲結果都應提供 baseline、patched runtime、Wine source revision、renderer、prefix、macOS 版本與是否在 Rosetta 下執行。只有 `patch --dry-run` 或 DLL 內含 marker 不足以證明 runtime 修正成立。
