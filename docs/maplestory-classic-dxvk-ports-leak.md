# 新楓之谷經典版：DXVK + MoltenVK Mach Ports 洩漏

更新日期：2026-08-01  
引擎：`CX26.3.0-W11-Cyder007`（runtime `~/.cyder/runtime/Engines/wine-x86_64`）  
相關：

- 商城／進場 wineserver 凍結：[maplestory-classic-wineserver-hang.md](./maplestory-classic-wineserver-hang.md)（穩定組合含 **MSync + DXVK**）
- 引擎 App overlay 契約：`cyder-wine-engine/docs/moltenvk-timeline-wait-poll-app-overlay.md`
- 引擎 patch 摘要：`cyder-wine-engine/patches/README.md`（MoltenVK 節）

**範圍：** Classic + DXVK 長跑時 wine 行程 Ports 暴增與對應修補。  
**不做：** 改遊戲／防作弊；不把此洩漏與 wineserver 無聲死亡混為同一根因。

## 1. 摘要

《新楓之谷：經典版》在 Cyder／CX26 上，**MSync + DXVK** 是目前較能穩定進出商城的組合；但 DXVK
走 Vulkan → MoltenVK 時，長時間遊玩會讓 wine 主行程的 **Mach Ports（receive rights）**
持續上升（實測約 **80+/s**），累積後卡頓，重啟遊戲才清除。

根因在 **MoltenVK host `vkWaitSemaphores*`**，不是 DXVK 本身、也不是 wineserver hang。
WineD3D／D3DMetal 通常不走此路徑，故無此 Ports 洩漏（但經典版上它們較易撞到
wineserver 相關不穩）。

修補方向：host wait **改輪詢 timeline counter**，避開
`-[MTLSharedEvent notifyListener:atValue:block:]`。引擎側有正式 patch 與等價
re-export shim；RC 可在不 bump 引擎版號下由 App／本機腳本注入 shim。

## 2. 症狀

| 項目 | 觀察 |
|------|------|
| 觸發條件 | Classic + **DXVK**（MoltenVK），長時間遊玩 |
| 指標 | Activity Monitor → wine／遊戲行程 → **Ports** 持續爬升 |
| 速率 | 約 80+ receive rights／秒（視場景與 wait 頻率） |
| 結果 | 後期明顯卡頓／僵死感；**重啟行程後 Ports 歸零** |
| 不觸發 | 同引擎下 WineD3D／D3DMetal（無此洩漏路徑；穩定性另論） |

與 [wineserver 凍結](./maplestory-classic-wineserver-hang.md) 的區分：

| | Ports 洩漏 | wineserver 無聲死亡 |
|--|------------|---------------------|
| 可見特徵 | Ports 數字持續上升 | `wineserver` 進程消失，client 永久 wait |
| 圖形後端 | 幾乎只見於 DXVK | WineD3D／部分組合較易出現；DXVK 反而是較穩組合 |
| 修復面 | MoltenVK host wait | wineserver／fd／sync 等（見該文件） |

兩者可同時存在於「建議用 DXVK」的產品決策中：DXVK 減輕 server hang 風險，但需另外堵住
Ports 洩漏。

## 3. 機制

1. DXVK 頻繁呼叫有限 timeout 的 `vkWaitSemaphores`／`vkWaitSemaphoresKHR`。
2. 上游 MoltenVK（含 1.4.2）經 `MVKFenceSitter` 註冊
   `MTLSharedEvent notifyListener`。
3. wait **先 timeout 放棄**時，Metal 側 pending 註冊**無法取消**；每個放棄的 wait 留下
   Mach receive right。
4. 上游相關議題（如 #1860）只釋放 listener 物件，**不**取消已登記的
   `notifyListener`，故單純升級 MoltenVK **不會**自動修好。

正式解法：`mvkWaitSemaphores` 改以 `getCounterValue()`（或 Vulkan
`vkGetSemaphoreCounterValue*`）輪詢，間隔約 **100µs**，完全不走 Metal listener。

## 4. 修補資產（`cyder-wine-engine`）

| 層級 | 路徑 | 說明 |
|------|------|------|
| 正式 patch | `patches/cyder-moltenvk-timeline-wait-poll.patch` | 改 `MVKSync.mm`；需 Xcode 重編 `libMoltenVK.dylib` |
| 等價 shim | `tools/cyder-mvk-timeline-wait-poll/` | Apple clang x86_64 re-export；攔截 `vkWaitSemaphores*` |
| 本機安裝 | `tools/cyder-mvk-timeline-wait-poll/install-shim.sh` | `--install-runtime` 寫入 Cyder engine tree；`--undo` 還原 |
| App RC 契約 | `docs/moltenvk-timeline-wait-poll-app-overlay.md` | 不 bump 引擎版號；ensure 後注入；正式 MoltenVK 進包後移除 |
| 重建腳本 | `scripts/rebuild-moltenvk-cyder-patches.sh` | 套用含 timeline-wait 在內的 Cyder MoltenVK patches |

Shim 目錄布局（runtime）：

```text
<engine>/lib/wine/x86_64-unix/
  libMoltenVK.dylib       ← wait-poll shim（小；marker: cyder-moltenvk-timeline-wait-poll）
  libMoltenVK.real.dylib  ← 原廠／引擎出貨 MoltenVK（大）
```

Wine／winevulkan 仍只 dlopen `libMoltenVK.dylib`。**禁止**對已是 shim 的 dylib 再備份成
`.real`（雙重包裝）。

相關但**非**本洩漏修補：`cyder-moltenvk-present-autoreleasepool.patch`（present 執行緒
autorelease）；`tools/cyder-mvk-autorelease/` 為診斷實驗，**不要**打進 App。

## 5. 本機套用與驗收

在 **`cyder-wine-engine`** 工作目錄：

```bash
bash tools/cyder-mvk-timeline-wait-poll/install-shim.sh --install-runtime
```

還原：

```bash
bash tools/cyder-mvk-timeline-wait-poll/install-shim.sh --undo --install-runtime
```

驗收：

- [ ] `strings …/libMoltenVK.dylib` 可見 `cyder-moltenvk-timeline-wait-poll`；且存在
      `.real`。
- [ ] 再跑一次 install → 不雙重包裝。
- [ ] Classic + DXVK 長跑：Activity Monitor **Ports 不再以 ~80/s 持續上升**。
- [ ] D3DMetal／WineD3D 仍可啟動（回歸）。
- [ ] shim `minos` ≤ 10.15（`otool -l`）。

有完整 Xcode 時：優先把 patch 編進引擎 MoltenVK，發新引擎包後拿掉 shim／App overlay。

## 6. 產品狀態（RC）

- 引擎版號可暫維持（例如 Cyder007）；shim 屬 **runtime overlay**，類似其他 App 對
  engine tree 的 sidecar／link，**不**改 pin 的引擎版號字串。
- ogom／Cyder.app 依 `cyder-wine-engine/docs/moltenvk-timeline-wait-poll-app-overlay.md`
  在 ensure 時冪等注入；正式修補 MoltenVK 進下一顆引擎 archive 後移除注入並 bump。
- 引擎 tarball／`pack-engine-artifact` **不必**含 shim（刻意；否則應 bump 引擎）。

## 7. 限制

- 只修 **host** `vkWaitSemaphores*`；不改變 GPU `encodeWait`／present。
- 輪詢略增成功長等待的 CPU；換不洩漏。無限 timeout 也走輪詢。
- 不解決 wineserver 無聲死亡；Classic 圖形後端選擇仍見
  [wineserver 凍結紀錄](./maplestory-classic-wineserver-hang.md)。
