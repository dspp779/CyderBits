# Cyder.app 打包注意事項：Wine Engine 路徑空白相容性

> 觀察日期：2026-07-13
>
> 狀態：已採用實體無空白 runtime 路徑作為正式 workaround

## 結論摘要

目前 CrossOver Wine engine 在路徑包含空白時，皮卡丘排球會在進入 demo 模式後於 `00402FA3` 發生 page fault；同一份 engine 複製到沒有空白的路徑後，使用全新 prefix 可以正常執行。

因此目前優先懷疑的是 Wine／CrossOver runtime 對 engine root、`WINESERVER` 或相關 dylib/resource 路徑的空白字元處理，而不是 Wine prefix 內的 Mono、字型、Retina 或 DPI 設定。

這不是 shell 引號問題。即使啟動指令正確引用了 `"$ENGINE/bin/wine"` 與 `"$ENGINE/bin/wineserver"`，仍可重現；改變 engine 的實際位置後結果才改變。

## 已驗證的現象

Cyder 預設 engine 路徑為：

```text
~/Library/Application Support/Cyder/Engines/wine-x86_64
```

其中 `Application Support` 含有空白。

### 失敗組

使用 Cyder 安裝的 engine，prefix 放在無空白路徑：

```bash
ENGINE="$HOME/Library/Application Support/Cyder/Engines/wine-x86_64"
P="$HOME/pika-cyder-test"

WINEPREFIX="$P" \
WINESERVER="$ENGINE/bin/wineserver" \
arch -x86_64 "$ENGINE/bin/wine" \
  /Users/jjc/ogom/dist/皮卡丘打排球.exe
```

結果：

```text
wine: Unhandled page fault on read access to ... at address 00402FA3
```

### 成功組

將同一個 `wine-x86_64` engine 複製到目前專案目錄，使 engine 路徑不含空白：

```bash
cp -pr "$HOME/Library/Application Support/Cyder/Engines/wine-x86_64" .
ENGINE="$PWD/wine-x86_64"
```

使用同一個 prefix 與同一個遊戲執行檔後，遊戲可以正常進入 demo 模式。

另外，`install/wine-experiments/a6-final-no-r4` 使用無空白路徑執行時也已正常。

當時 Cyder 安裝版與 A6-final-no-r4 的 `winemac.so` SHA-256 均為：

```text
814358c0b459b3e4b2735b604ba038dd166f72561e9425676b57f323d7aafbab
```

因此目前觀察到的差異是 runtime path，而不是已確認的 `winemac.so` binary 內容差異。

## 已排除或降低優先度的因素

上述測試使用全新 prefix，沒有執行 Cyder bootstrap，因此已先排除：

- FontReplacement
- RetinaMode
- LogPixels / DPI
- FontSmoothing
- Wine Mono
- libarchive/tar 安裝
- `.cyder-bootstrap-v1` marker

`wineboot -u` 輸出的 `winebth`、`wineusb`、Common-Controls、OLE 與 setupapi 訊息，在 prefix 建立階段出現，暫時視為此 CrossOver Wine 的初始化噪音；目前沒有證據顯示它們是 `00402FA3` 崩潰的直接原因。

## 目前的工作假設

### 假設 A：engine 路徑解析不支援空白

Wine 啟動器或 macOS driver 可能在以下其中一處以未正確 escape 的方式使用 engine 路徑：

- `WINESERVER` 執行檔路徑
- `winemac.so` 的載入或相依 dylib 路徑
- engine root 的 resource／registry／Wine loader 路徑
- CrossOver 對 `realpath`、`dlopen` 或子程序啟動的封裝

這可以解釋為何 prefix 不變、遊戲不變，只搬移 engine 就改變結果。

### 假設 B：symlink 與實體複製的行為不同

若無空白 symlink 也能正常，問題主要是傳入的路徑字串；若只有實體複製正常，則還要考慮：

- Wine 是否解析 symlink 後又取得含空白的真實路徑
- engine 檔案的 code-sign / xattr / dylib relocation 狀態
- `cp` 是否改變了檔案 metadata

## 後續驗證矩陣

每一組都使用全新 prefix，並等待至少 30 秒：

| 組別 | Engine 路徑 | Prefix 路徑 | 目的 |
|---|---|---|---|
| E0 | 無空白實體路徑 | 無空白 | 已知成功基準 |
| E1 | `Application Support` 原路徑 | 無空白 | 已知失敗組 |
| E2 | 無空白 symlink | 無空白 | 判斷是否只與傳入字串有關 |
| E3 | 無空白實體路徑 | `Application Support` 路徑 | 分離 prefix 空白因素 |
| E4 | `~/.cyder/runtime/Engines` | 正式 `bottles/shared` | 打包後驗收 |

E2 可用以下方式測試，不必再次複製整個 engine：

```bash
ORIG="$HOME/Library/Application Support/Cyder/Engines/wine-x86_64"
LINK="$HOME/cyder-engine-link"
P="$HOME/pika-cyder-link-test"

rm -f "$LINK"
ln -s "$ORIG" "$LINK"
rm -rf "$P"
mkdir -p "$P"

ENGINE="$LINK"
WINEPREFIX="$P" \
WINESERVER="$ENGINE/bin/wineserver" \
arch -x86_64 "$ENGINE/bin/wine" wineboot -u

WINEPREFIX="$P" \
WINESERVER="$ENGINE/bin/wineserver" \
arch -x86_64 "$ENGINE/bin/wine" \
  /Users/jjc/ogom/dist/皮卡丘打排球.exe
```

## Cyder.app 打包建議

### 正式 workaround

不要將可執行的 engine runtime 直接放在含空白的路徑下使用。Cyder 採用：

```text
~/.cyder/runtime/Engines/wine-x86_64
```

設定與 bottle 仍保留在 `~/Library/Application Support/Cyder/`；預設 bottle 改為 `bottles/shared`，為未來多 bottle 預留結構。正式 runtime 不使用 symlink；舊 `Application Support/Cyder/Engines` 會在安全遷移時移除，再由 app 內正式 artifact 重建。

### `WINESERVER` 與 `PATH`

啟動時必須使用同一個 engine 的 `wineserver`，並將 engine 的 `bin` 放在 `PATH` 前方：

```bash
WINEPREFIX="$PREFIX" \
WINESERVER="$ENGINE/bin/wineserver" \
PATH="$ENGINE/bin:$PATH" \
arch -x86_64 "$ENGINE/bin/wine" "$EXE"
```

不能只依賴系統 PATH 中的 `wineserver`。此外，即使 `WINESERVER` 已正確設定，engine root 含空白仍可能觸發此問題，因此 `WINESERVER` 修正不能取代無空白 engine 路徑驗證。

### 打包流程應加入的檢查

1. 建置或安裝 engine 後，檢查實際 runtime path 是否含空白。
2. 以「含空白 engine 路徑」和「無空白 engine 路徑」各跑一次 30 秒遊戲 smoke test。
3. 確認 `wine`、`wineserver`、`winemac.so` 都來自同一份 engine。
4. 若無法立即修正 Wine 的路徑處理，將 engine 實體複製到無空白 cache，而不是只依賴 symlink。
5. 將 engine relocation、code-sign 與 ad-hoc sign 放在最後，並在 relocation 後再次執行 E4。
6. 專案目錄中的暫時 engine 複製品不應被提交；打包應只使用 `dist/artifacts/` 中的正式 engine artifact。

## Cyder 原始碼對照點

- [scripts/cyder-common.sh](../scripts/cyder-common.sh)：`cyder_run_wine_exe()` 設定 `WINEPREFIX`、`WINESERVER`、`PATH`。
- [scripts/cyder_app_main.swift](../scripts/cyder_app_main.swift)：`wineEnvironment()` 建立 Finder 啟動時的 Wine 環境。
- [scripts/create-cyder-app.sh](../scripts/create-cyder-app.sh)：將 engine artifact 安裝至 Cyder 的 runtime 位置。
- [docs/bluecg-winemac-a6-engine.md](bluecg-winemac-a6-engine.md)：A6-final engine 的版本與 artifact 資訊。

目前不應因為此現象重新修改 A6 backing-sync patch；先完成 E2、E3 與 E4，確認問題確實是路徑／打包位置後，再決定要修正 Cyder 的 engine cache 位置，或回頭修正 Wine loader 的空白路徑處理。
