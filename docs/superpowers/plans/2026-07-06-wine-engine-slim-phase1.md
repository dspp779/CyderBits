# Wine Engine 瘦身 Phase 1：Configure Profile 與 Runtime Artifact

> **修訂日期**：2026-07-15
>
> **目標**：以可重現的 CrossOver configure profile、`install-lib` 與 debug-symbol 實驗縮小 Cyder engine；不使用 Sikarugir allowlist。
>
> **Spec**：[2026-07-06-wine-engine-slim-design.md](../specs/2026-07-06-wine-engine-slim-design.md)

## 1. 成功定義

Phase 1 不預設承諾某個解壓尺寸。成功條件是：

- 可從 clean source 重現 `compat` 與 `classic-safe` build。
- 發布 tree 使用 `make install-lib`，不再先安裝完整 development environment。
- 可產生同 build ID 的 runtime 與 symbols artifact。
- 每個 configure flag 有 install/archive/dylib/capability diff。
- 通過自動測試與既定多遊戲 smoke matrix。
- 結論可以是「configure 對壓縮大小收益不足，不採用」，只要量測完整。

## 2. File map

| File | Responsibility |
|---|---|
| `config/wine-build-profiles/compat.conf` | 目前完整相容性基準 |
| `config/wine-build-profiles/classic-safe.conf` | 老遊戲保守精簡 profile |
| `scripts/build-wine.sh` | `--profile`、clean build/cache、`install-lib` |
| `scripts/analyze-wine-engine.sh` | install/archive/sections/dylib/capability 報告 |
| `scripts/pack-engine-artifact.sh` | runtime archive、manifest、checksum |
| `scripts/split-wine-debug-symbols.sh` | PE/Unix debug symbols 實驗；只操作 staging |
| `tests/test-build-wine.sh` | profile 參數、互斥與 install target |
| `tests/test-wine-engine-profile.sh` | manifest 與產物一致性 |
| `docs/wine-configure-options.md` | profile 與 flag 影響 |

## 3. Task 1 — 凍結 baseline report

- [ ] 在不改動現有 install tree 的前提下輸出：
  - configure command／source version／compiler version
  - install logical/allocated bytes
  - x86/x64 PE、Unix library、bundled dylib、include/bin/share 分項
  - tar.xz exact bytes 與 compression ratio
  - 最大 30 個檔案及 PE debug section 摘要
  - non-system dylib closure
- [ ] 報告使用 exact bytes；`du -sh` 只作人類可讀補充。
- [ ] 保存目前 CX26 artifact 作 `compat` 對照。

驗收基準應記錄目前 artifact 約 `162,637,668 / 1,054,883,840 = 0.154`，但不可把這組數字硬編碼成未來版本的成功條件。

## 4. Task 2 — Build profiles

- [ ] `build-wine.sh` 新增 `--profile compat|classic-safe`。
- [ ] profile 使用受版本控制的參數清單，不接受 shell source／eval。
- [ ] `--with-vulkan`／`--without-vulkan` 與 profile 衝突時明確報錯或要求 override flag，不能靜默覆寫。
- [ ] dry-run 印出唯一、完整、可複製的 configure command。
- [ ] build manifest 記錄 profile 與 resolved flags。

`classic-safe` 第一批候選：

```text
--disable-tests
--disable-win16
--without-vulkan
--without-capi
--without-cups
--without-gphoto
--without-gssapi
--without-krb5
--without-opencl
--without-pcap
--without-pcsclite
--without-sane
--without-v4l2
--without-wayland
```

保留 GnuTLS、FFmpeg、GStreamer、USB、SDL、NetAPI、inotify、OpenGL、CoreAudio、FreeType、pthread、unwind。

## 5. Task 3 — Clean profile matrix

- [ ] 每個 profile／單一 flag 使用獨立 build directory 與 cache，或完全清除 `config.cache`。
- [ ] 至少建立：
  1. compat
  2. compat + disable-tests
  3. compat + disable-win16
  4. compat + without-vulkan
  5. classic-safe
- [ ] 保存 configure summary 與產生／未產生 target 差異。
- [ ] 不把「依賴原本就未偵測到」列為 flag 的大小收益。

## 6. Task 4 — Runtime-only install

- [ ] 將發布 staging 從 `make install` 改為 `make install-lib`。
- [ ] 開發需要 headers/tools 時，另提供 `make install-dev` 的 opt-in 路徑，不混入 engine artifact。
- [ ] `bundle-wine-dylibs.sh`、relocation、signing 在 runtime staging 上重新執行並驗證。
- [ ] 比較 `install` 與 `install-lib` 的檔案清單、install bytes、archive bytes。
- [ ] 確認 runtime 仍有 `wine`、`wineserver`、wineboot、reg、cmd、winemenubuilder 等實際啟動需要的檔案。

## 7. Task 5 — Debug symbols spike

- [ ] 找到 build 使用的 LLVM-MinGW `llvm-strip`／`llvm-objcopy`；拒絕 macOS `/usr/bin/strip`。
- [ ] 只在 staging copy 執行，先挑 x86/x64 `wined3d.dll`、`mshtml.dll`、`msxml3.dll` A/B。
- [ ] 比較：
  - 原始 PE bytes
  - strip 後 PE bytes
  - 各自單檔 xz bytes
  - 完整 engine tar.xz bytes
  - Wine 載入與 codesign 結果
- [ ] 決定採「直接 strip」或「split symbols + runtime strip」。
- [ ] symbols artifact 必須包含 engine ID/build ID manifest，並能對應 crash report。

## 8. Task 6 — Artifact manifest 與分析工具

- [ ] `pack-engine-artifact.sh` 輸出 machine-readable manifest：
  - profile、resolved configure flags
  - source/compiler/build ID
  - engine/archive bytes
  - symbols mode
  - capabilities（PE32、OpenGL、CoreAudio、media、TLS、Vulkan、Win16）
- [ ] `analyze-wine-engine.sh compare A B` 顯示 exact delta，不依賴 Sikarugir 路徑。
- [ ] CI／release log 同時顯示 compressed 與 installed 指標。

## 9. Task 7 — 回歸驗證

### 自動化

- [ ] `bash tests/test-build-wine.sh`
- [ ] `bash tests/test-wine-engine-profile.sh`
- [ ] `bash tests/test-cyder-engine-tarball.sh`
- [ ] `bash tests/test-cyder-bootstrap.sh`
- [ ] `bash scripts/verify-bluecg.sh`
- [ ] codesign、dylib closure、archive checksum／extract

### 手動遊戲矩陣

- [ ] BlueCG：Mono、DirectDraw、CoreAudio、Retina。
- [ ] 皮卡丘排球：PE32、sync off。
- [ ] 大富翁 4：cnc-ddraw。
- [ ] LF2：vcrun2005、wmp9、quartz、devenum、vb6run、影片／音訊。
- [ ] TLS／網路案例。
- [ ] USB／SDL 輸入案例；沒有案例前不得移到 safe disable list。

## 10. Task 8 — 決策報告

每個 flag／處理步驟填一列：

| Candidate | Install delta | Archive delta | Dylib delta | Capability loss | Tests | Decision |
|---|---:|---:|---|---|---|---|
| `install-lib` | TBD | TBD | TBD | dev only | TBD | TBD |
| split/strip debug | TBD | TBD | none expected | diagnostics | TBD | TBD |
| `--disable-win16` | TBD | TBD | TBD | Win16 | TBD | TBD |
| `--without-vulkan` | TBD | TBD | MoltenVK | Vulkan/DXVK | TBD | TBD |
| `classic-safe` | TBD | TBD | TBD | manifest | TBD | TBD |

合併門檻：

- 必要測試全部通過。
- 沒有新的 missing DLL/dylib。
- 若 configure profile 的 archive 改善小於 5% 或 10 MB，且沒有其他明確維護／安全收益，不增加正式 profile。
- strip 若只改善 installed size，也可採用，但必須先完成 symbols 策略。

## 11. 明確移除的舊任務

以下不再執行：

- 匯出 `sikarugir-x64.txt`／`sikarugir-x86.txt`。
- 以 Sikarugir 檔名作 B-1 allowlist prune。
- 以 Sikarugir 約 295 MB PE 作 Phase 2 目標。
- 未經 dependency/game matrix 就刪除 IE、printing、media、XML 類 Windows DLL。
- 把解壓大小當成唯一成功指標。

## 12. 建議執行順序

```text
Task 1 baseline
  → Task 2 profiles
  → Task 3 clean matrix ──────┐
  → Task 4 install-lib        ├→ Task 6 manifest
  → Task 5 symbols spike ─────┘
                              → Task 7 regression
                              → Task 8 decision
```

Task 3、4、5 可由不同 Agent 執行，但必須共用 Task 1 的量測格式，且不能修改同一 install tree。
