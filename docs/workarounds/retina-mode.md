# RetinaMode 遊戲視窗 workaround

`RetinaMode=y` 搭配 `LogPixels=192`（200% DPI）可讓舊 Windows 遊戲以較高 backing resolution 繪製；專案腳本也會設定字體平滑。套用／還原：

```bash
bash scripts/enable-mac-retina-hires.sh --on
bash scripts/enable-mac-retina-hires.sh --off
```

一般遊戲未必能在 RetinaMode 下安全 live resize。BlueCG 的 CX26 原版／A2／A4 曾有黑屏或黑邊，現在應使用 [A6 same-view backing sync](bluecg-a6-resize.md)；沒有 A6 的 runtime 時，進入遊戲世界前調好視窗並避免之後拖曳，是保守 workaround。

RetinaMode、DPI、字體平滑是不同設定；Cyder 的進階設定預設建議為 Retina 開、DPI 192、灰階字體平滑。
