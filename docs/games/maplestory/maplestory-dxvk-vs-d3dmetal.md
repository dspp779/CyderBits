# 新楓之谷：dxvk vs d3dmetal

> 狀態：**測試中**（2026-07-27）


精準結論是：D3DMetal 的平均幀率較高，但 DXVK 的最差單幀、GPU 時間與記憶體使用較好。兩者目前都不是 GPU 算力受限，主要差異比較可能發生在 CPU、轉譯層、同步與畫面提交路徑。

| 指標 | D3DMetal | DXVK | 判讀 |
|---|---:|---:|---|
| 平均 FPS | 126.93 | 119.05 | D3DMetal 高 6.62% |
| 最低 FPS | 23.98 | 28.77 | DXVK 最差情況高 19.97% |
| 最高 FPS | 143.86 | 143.86 | 都碰到 144 Hz 上限 |
| 平均 Frame Interval | 7.88 ms | 8.40 ms | D3DMetal 低 6.19% |
| 最差 Frame Interval | 41.71 ms | 34.76 ms | DXVK 的最差卡頓短 16.7% |
| 平均 GPU Time | 0.66 ms | 0.52 ms | DXVK 低 21.2% |
| 最大 GPU Time | 2.76 ms | 2.10 ms | DXVK 低 23.9% |
| Process Memory | 5.15 GB | 4.41 GB | DXVK 少 0.74 GB |
| Metal Allocation | 2.43 GB | 1.48 GB | DXVK 少 0.95 GB |

### 幀率與流暢度

D3DMetal 平均達到 126.93 FPS，比 DXVK 的 119.05 FPS 高約 7.88 FPS。對應的平均 frame interval 是：

- D3DMetal：7.88 ms
- DXVK：8.40 ms
- 144 Hz 的理想 frame budget：6.94 ms

所以 D3DMetal 的平均吞吐量確實比較好，更接近 144 Hz。

但最差單幀呈現相反結果：

- D3DMetal 最差 41.71 ms，等於瞬間 23.98 FPS。
- DXVK 最差 34.76 ms，等於瞬間 28.77 FPS。

數值完全互相吻合：

```text
1000 / 41.71 = 23.98 FPS
1000 / 34.76 = 28.77 FPS
```

因此可以把目前的特性概括為：

- D3DMetal：大部分時間更快，但偶爾會出現更嚴重的長幀。
- DXVK：平均稍低、圖上中型尖峰較多，但最差尖峰沒有 D3DMetal 那麼深。

如果遊戲體感重視快速移動、技能施放時不突然頓一下，DXVK 的 worst-case 表現目前反而略好；若重視一般場景的平均 FPS，D3DMetal 領先。

### 這不是 1% low

HUD 紅色的第二欄不是 1% low，而是最近 1200 幀中的最低值；白色第一欄是最近 120 幀平均，第三欄則是最近1200幀最高值。Apple 的正式效能報告才會另外計算 1% low 與 99% high。[Apple：Monitoring Metal app graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance/)

所以這兩張圖只能得出「最低單幀」結論，不能宣稱 D3DMetal 的 1% low 是 23.98 FPS。

### GPU 並不是瓶頸

兩者的 GPU time 都非常低：

- D3DMetal：平均 0.66 ms，約佔 7.88 ms frame interval 的 8.38%。
- DXVK：平均 0.52 ms，約佔 8.40 ms 的 6.19%。

即使最高 GPU time 也只有 2.76 ms 與 2.10 ms，遠低於 6.94 ms 的 144 Hz 預算。

這表示目前的掉幀尖峰不是 M4 GPU 畫不動。41.71 ms 的長幀中，GPU 最多只工作 2.76 ms，其餘時間更可能消耗在：

- 遊戲主執行緒或 Wine/Rosetta。
- D3D11 API translation。
- Shader/pipeline 建立。
- CPU-GPU 同步或 swapchain 等待。
- 素材載入、反作弊程序或遊戲網路更新。
- Metal HUD/WindowServer composition。

Apple 將 GPU Time 定義為 command buffer 從 GPU 開始到完成的時間，而 Frame Interval 是相鄰 drawable 實際顯示的時間差，因此兩者差距很大時，通常不屬於純 GPU bottleneck。[Apple：Understanding Metal Performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)

### DXVK 的資源效率明顯較好

DXVK 使用：

- Process memory 少 0.74 GB，約少 14.4%（以 D3DMetal 為基準）。
- Metal allocation 少 0.95 GB，約少 39.1%。
- D3DMetal 的 Metal allocation 是 DXVK 的 1.64 倍。

Apple HUD 的 `Mem` 第一個值是程序目前使用的記憶體，括號內則是 Metal device 的 `currentAllocatedSize`。[Apple：Understanding Metal Performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)

不過這仍可能受到場景、遊戲已運行時間及 shader cache 熱身程度影響。若多次測量都維持約 1 GB 差距，就可以確認 D3DMetal 的資源配置策略確實比較積極。

### Direct 與 Composited 是重要變因

兩張圖的呈現模式不同：

- D3DMetal：`Composited`
- DXVK：`Direct`

這代表 D3DMetal 畫面當時經過合成路徑，而 DXVK 的 drawable 可走直接呈現。這不一定是後端本身造成，也可能受視窗狀態、HUD、縮放、其他視窗遮擋和桌面合成條件影響。

因此這次甚至是在 DXVK 擁有 Direct 優勢的情況下，D3DMetal 平均 FPS 仍較高，這讓 D3DMetal 的平均效能結果相當有意思；但在兩者 present mode 相同前，不能把 6.62% 全部歸功於圖形後端。

### D3DMetal 額外資訊

D3DMetal 畫面明確顯示：

```text
Rosetta x86_64 v3.0 D3D11
```

這證實該次確實走 GPTK 3.0 的 D3D11 路徑，而不是 WineD3D。當下工作量為：

- 2 個 command buffers
- 6 個 render encoders
- 190 個 draw calls
- 5 次 clear
- 沒有 compute、blit、geometry shader 或 tessellation

這是一個相當輕的 2D workload，也再次解釋為什麼 M4 GPU time 不高。

### 最終判斷

目前這一組結果，我會這樣排名：

- 平均 FPS：D3DMetal 勝。
- 最差單幀：DXVK 勝。
- GPU 效率：DXVK 勝。
- 記憶體效率：DXVK 明顯勝。
- 是否真正比較流暢：尚不能只憑截圖定論，但 D3DMetal 偏向高平均、偶發大頓；DXVK偏向較低平均、較多小幅波動。

要得到真正可靠的勝負，下一輪應固定同一張地圖、相同角色位置、相同 Direct/Composited 模式，分別錄製至少 60 秒的 Metal Performance Report。報告會直接產生 1% low、99% high、frame interval distribution 與完整平均/極值，而不是只取兩個不同時間點的 HUD 快照。[Apple：Generating performance reports](https://developer.apple.com/documentation/xcode/generating-performance-reports-with-metal-performance-hud)