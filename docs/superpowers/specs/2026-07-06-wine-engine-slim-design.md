# Wine Engine 瘦身設計（Windows on Wine PE）

> **日期**：2026-07-06  
> **狀態**：已核准方向，待分階段實作  
> **Phase 1 計畫**：[2026-07-06-wine-engine-slim-phase1.md](../plans/2026-07-06-wine-engine-slim-phase1.md)  
> **相關**：[Cyder 分流設計](2026-07-05-cyder-cyderbits-split-design.md)、[可攜打包](2026-07-04-portable-app-packaging-design.md)、[文件索引](../../README.md#未來開發路線)

## 1. 問題

`Cyder.app` 約 **1.1 GB**，其中 `Contents/Resources/engine-payload/` 占 **~1.1 GB**。對照 `dist/Sikarugir Creator.app` 僅 **~4 MB**（Engine 改首次下載，壓縮包 **~159 MB**，解壓 **~750 MB**）。

玩家關心的是 **下載體積** 與 **磁碟占用**；兩者皆可從「Windows on Wine」的 PE 假 DLL 與非 runtime 檔案下手。

## 2. 基準量測（本機 2026-07-05）

### 2.1 Cyder `install/wine-x86_64`（= engine-payload 來源）

| 路徑 | 大小 | 檔案數（約） |
|------|------|--------------|
| `lib/wine/x86_64-windows` | 529 MB | 1,013 |
| `lib/wine/i386-windows` | 468 MB | 1,065 |
| **PE 合計** | **997 MB** | 2,078 |
| `include/` | 62 MB | — |
| `share/man` | 0.15 MB | — |
| `bin` 開發工具（winegcc, widl, wrc, wmc, winebuild） | 1.6 MB | — |
| 其餘（x86_64-unix、bin/wine 等） | ~18 MB | runtime 必要 |

### 2.2 Sikarugir `wswine.bundle`（對照）

| 路徑 | 大小 | 檔案數（約） |
|------|------|--------------|
| `lib/wine/x86_64-windows` | 150 MB | 743 |
| `lib/wine/i386-windows` | 145 MB | 802 |
| **PE 合計** | **295 MB** | 1,545 |
| `share/wine/mono` | 230 MB | 在 engine 內 |
| `share/wine/gecko` | 207 MB | 在 engine 內 |
| `include/` | 無 | — |

Cyder 將 **Mono 裝在 prefix**（bootstrap）、**停用 mshtml**（`WINEDLLOVERRIDES=mshtml=`），故 engine 不含 mono/gecko  bulk；Sikarugir 則 bundled 在 engine。

**PE 差距：Cyder − Sikarugir ≈ 702 MB（−70%）。**

## 3. 根因

1. **`make install` 全量 PE**：upstream/CrossOver 原始 build 安裝所有 builtin DLL，Cyder 現況未 prune。  
2. **同名 DLL 體積更大**：兩邊檔名交集占多數，但 Cyder 的 `mshtml.dll`、`wined3d.dll`、`msxml3.dll` 等明顯大於 Sikarugir（精簡 build 或編譯選項不同）。僅刪「Cyder 獨有檔名」无法接近 295 MB。  
3. **非 runtime 夾帶**：`include/`、`*.a` 靜態庫、部分 dev 工具 — 執行期不需要。  
4. **App 內嵌 engine**：`create-cyder-app.sh` rsync 整棵 `WINE_INSTALL` → `.app` 膨脹；與 Sikarugir「小 app + 下載 engine」交付模型不同（可列後續 Phase，非 PE 瘦身本體）。

## 4. Wine 架構備忘（影響取捨）

| 層 | Engine（`lib/wine/*-windows/`） | Prefix（`WINEPREFIX/drive_c/`） |
|----|--------------------------------|----------------------------------|
| HTML | `mshtml.dll` 等（大檔，API+橋接） | Wine Gecko（按需安裝） |
| .NET | `mscoree.dll` 等（載入器） | Wine Mono（bootstrap MSI） |
| Cyder 預設 | 檔仍在 engine | `mshtml=` 不裝 Gecko；**裝 Mono**（BlueLauncher） |

- **刪 engine 內 `mshtml*.dll`**：與 `mshtml=` 一致，省空間；內嵌 HTML 的程式可能失效。  
- **不可刪 `mscoree.dll`**：BlueCG `BlueLauncher.exe` 為 .NET，需保留載入器 + prefix Mono。  
- **Gecko**：Cyder 已策略性不需要；Sikarugir engine 內 207 MB gecko 對 Cyder 非目標。

## 5. 方案摘要

### Plan B — Sikarugir 檔名 allowlist

| 子方案 | 作法 | 可省 PE | 刪後 PE（約） |
|--------|------|---------|---------------|
| **B-1** | 刪 Cyder 有、Sikarugir 無的檔（546 檔） | **37 MB** | ~960 MB |
| **B-2** | B-1 + 對齊 Sikarugir 同名 DLL 體積（精簡 build） | **~702 MB** | **~295 MB |

B-1 主成分：`*.a` 靜態庫（~503 檔）、`comctl32_v6.dll`、`winemenubuilder.exe` 等。  
B-2 需 **編譯期/商用級精簡 tree**，非單純刪檔腳本。

Sikarugir 有、Cyder 無（對齊時可能需補）：`winemetal.dll`、`twain_32.dll`、`winegstreamer.dll`。

### Plan C — 保守類別 prune

依 DLL 類別刪除（Cyder 兩棵 PE 樹內匹配）：

| 類別 | 小計 | 風險 |
|------|------|------|
| legacy_ie_html（mshtml, jscript, vbscript…） | 63 MB | 低（Cyder 已 `mshtml=`） |
| msxml_optional | 19 MB | 中（部分啟動器可能用 msxml3） |
| media_codecs | 14 MB | 低～中 |
| odbc_database | 3 MB | 低 |
| printing | 3 MB | 低 |
| scanner_imaging | 2 MB | 低 |
| dotnet（含 mscoree） | 2 MB | **高 — 預設不刪 mscoree** |
| fax_modem、telephony | 1 MB | 低 |
| **合計（含 dotnet 類全部）** | **108 MB** | 可配置 |

**C 與 B 重疊極小**（B-only ∩ C ≈ `twaindsm.dll`）；C 多數命中「兩邊都有的檔」，不會單靠 C 達 Sikarugir 體積。

### 非 PE 剝離（任何 Phase 可做）

| 項目 | 可省 |
|------|------|
| `include/` | ~62 MB |
| dev `bin` 工具 | ~1.6 MB |
| `share/man` | 可忽略 |

## 6. 建議路線（分 Phase）

```text
Phase 1（低風險、快）
  strip include/ + dev bin
  Plan B-1 allowlist prune（*.a 等）
  Plan C 可配置 manifest（預設：ie_html + printing + media；保留 msxml + mscoree）
  整合進 create-cyder-app.sh 前處理
  回歸：verify-bluecg G3、test-cyder-bootstrap

Phase 2（中～高工時、最大效益）
  調查 CrossOver/Sikarugir 精簡 build（configure 或 install 後處理）
  對齊 B-2：PE ~295 MB 級
  產物：engine tarball + 版本化 allowlist

Phase 3（交付模型，可選）
  Cyder.app 不內嵌 engine；首次下載 tar.xz（~150–200 MB）
  沿用 ensure_shared_engine 裝到 Application Support
  與 Phase 1/2 正交（engine 瘦 + 下載）
```

### Phase 1 粗估

| 項目 | App/engine 節省 |
|------|-----------------|
| include + dev bin | ~64 MB |
| B-1 | ~37 MB |
| C（保守預設，不含 msxml/dotnet） | ~80 MB |
| **合計** | **~180 MB** → engine **~820 MB**，app **~820 MB** |

### Phase 2 粗估

| 項目 | 節省 |
|------|------|
| PE 對齊 Sikarugir | **~702 MB** → engine **~295 MB** |

## 7. 元件設計（Phase 1）

| 元件 | 職責 |
|------|------|
| `tools/wine-pe-allowlist/` | B-1 檔名清單（x64/x86）、C 類別 manifest |
| `scripts/strip-wine-install.sh` | 刪 include、man、dev bin、*.a |
| `scripts/prune-wine-pefiles.sh` | 依 allowlist / category 刪 PE |
| `scripts/analyze-wine-pe.sh` | 量測、diff Sikarugir、輸出報告（開發用） |
| `create-cyder-app.sh` | 打包前呼叫 strip + prune |
| `build-wine.sh`（可選 hook） | install 後自動 strip |

**介面：**

```bash
# 對已安裝的 WINE_INSTALL 操作（不修改 sources）
bash scripts/strip-wine-install.sh "$WINE_INSTALL"
bash scripts/prune-wine-pefiles.sh --plan b1 "$WINE_INSTALL"
bash scripts/prune-wine-pefiles.sh --plan c --profile cyder-default "$WINE_INSTALL"
```

## 8. 測試與驗收

| 閘 | 指令 / 條件 |
|----|-------------|
| G0 | `du -sh install/wine-x86_64/lib/wine/*-windows` 符合預期上限 |
| G1 | `wine --version`、`winecfg` 可開 |
| G2 | `bash scripts/verify-bluecg.sh` G3 BlueLauncher UI |
| G3 | `tests/test-cyder-bootstrap.sh` mono + tar + hi-res |
| G4 | 手動開 1–2 個非 BlueCG `.exe` smoke（可選） |

Phase 2 額外：與 Sikarugir PE 檔名集合 diff ≤ 允許差集。

## 9. 非目標（本設計）

- 移除 WOW64 / `i386-windows` 整樹（BlueCG 為 PE32）  
- 預設刪 `mscoree.dll` 或 bootstrap 不裝 Mono  
- Phase 1 不做首次下載 engine UI（屬 Phase 3）  
- 修改 Wine 原始碼大量 `--disable-*`（留 Phase 2 調查）

## 10. 待決（實作前可定）

- [ ] Plan C 預設 profile：`msxml` 是否保留（建議 **保留**）  
- [ ] Plan C 是否提供 `--profile aggressive` 供開發者自測  
- [ ] Phase 2 是否以 Sikarugir `wswine.bundle` 為 golden allowlist，或重新從 CrossOver build 導出  
- [ ] Phase 3 下載 URL / 版本鎖定策略  

## 11. 參考路徑

- 量測清單（本機）：`/tmp/cyder-plan-b-remove.txt`、`/tmp/cyder-plan-c-remove.txt`（可重建：`scripts/analyze-wine-pe.sh`）  
- Sikarugir 對照：`dist/Sikarugir/Engines/wswine.bundle`  
- Cyder 打包：`scripts/create-cyder-app.sh` → `engine-payload/`
