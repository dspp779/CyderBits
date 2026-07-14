# BlueCG A2 engine artifact

> 建立日期：2026-07-12
>
> **狀態：歷史對照 artifact，不是目前正式 BlueCG engine。** A2 只修正非 Retina guard；需要 Retina+DPI resize 請使用 [A6 final](bluecg-winemac-a6-engine.md)。

## 發行識別

本次 A2 engine 使用識別碼：

```text
CX26.2.0-W11-A2-Cyder0.0.2
```

識別碼含義如下：

| 欄位 | 意義 |
|------|------|
| `CX26.2.0` | CrossOver 26.2.0 基線 |
| `W11` | Wine 11.0 |
| `A2` | BlueCG winemac guard-only resize 實驗組 A2 |
| `Cyder0.0.2` | 供 Cyder 0.0.2 流程識別的包裝標籤 |

目前工具會將版本標籤中的小數點正規化為連字號，因此 archive 檔名為：

```text
dist/artifacts/a2/engine-wine-x86_64-CX26-2-0-W11-A2-Cyder0-0-2.tar.xz
```

這個檔案是現行 engine 介面使用的 `tar.xz` 格式，解開後的根目錄為
`wine-x86_64/`。A2 runtime 的遊戲測試結果與限制請參考
[`bluecg-winemac-experiments.md`](bluecg-winemac-experiments.md)：目前已確認
`RetinaMode=n` 拖曳不黑屏；`RetinaMode=y` 仍會黑屏，因此不能把這個包標示為
Retina 完整修復版。

## 建置來源與可重現指令

來源 runtime：

```text
install/wine-experiments/a2
```

重新打包（不會覆蓋正式 CX26 engine 的 metadata）：

```bash
cd /Users/jjc/ogom
CYDER_ENGINE_VERSION_LABEL='CX26.2.0-W11-A2-Cyder0.0.2' \
CYDER_ENGINE_ARTIFACTS_DIR="$PWD/dist/artifacts/a2" \
WINE_INSTALL="$PWD/install/wine-experiments/a2" \
bash scripts/pack-engine-artifact.sh --xz --force
```

打包流程會對暫存副本執行 runtime strip、dylib relocation、ad-hoc code-sign，
不會修改 `install/wine-experiments/a2` 原始 runtime。

## 驗證資訊

建置完成時的 SHA-256：

```text
e5f8096f770b6d9cf5a3931ccca2e74b52c537273076c930e396711a8f1e7ff5
```

可用下列指令檢查檔案、版本與 A2 `winemac.so`：

```bash
cd /Users/jjc/ogom
ART='dist/artifacts/a2/engine-wine-x86_64-CX26-2-0-W11-A2-Cyder0-0-2.tar.xz'
shasum -a 256 "$ART"
tar -xOf "$ART" wine-x86_64/version
tar -xOf "$ART" wine-x86_64/winemac.sha256
tar -tJf "$ART" | rg \
  'wine-x86_64/(bin/wine|bin/wineserver|lib/wine/x86_64-unix/winemac.so)$'
```

`dist/artifacts/a2/engine-version.txt` 與 `.pack-stamp` 是同一組包的 metadata；
請與 archive 一起保存。若要把 A2 包進 Cyder.app，建立 app 時明確傳入 archive
路徑，避免誤用正式 engine：

```bash
bash scripts/create-cyder-app.sh \
  --engine-archive "$PWD/dist/artifacts/a2/engine-wine-x86_64-CX26-2-0-W11-A2-Cyder0-0-2.tar.xz"
```
