# 皮卡丘排球：runtime 路徑與 MSync／ESync

> 狀態：**已知相容性問題；workaround 可用，根因未修復**（2026-07）

## 觀察矩陣

| Engine 實際路徑 | MSync | ESync | 結果 | 判定 |
|---|---:|---:|---|---|
| 含空白（例如 `~/Library/Application Support/...`） | 開 | 關 | demo 模式附近 page fault（`00402FA3`） | 失敗 |
| 含空白 | 關 | 開 | 不應作為可用設定；同步模式本身亦已知不相容 | 失敗 |
| 不含空白實體路徑 | 開 | 關 | 皮卡丘排球無法正常運作 | 失敗 |
| 不含空白實體路徑 | 關 | 開 | 皮卡丘排球無法正常運作 | 失敗 |
| 不含空白實體路徑 | 關 | 關 | 目前建議的相容性基線 | workaround |

含空白路徑的失敗與 MSync／ESync 是兩個可疊加的條件：即使 shell 已正確引用 `"$ENGINE/bin/wine"`，搬移同一份 engine 到無空白實體路徑後結果仍會改變，因此不能只當成 shell quoting 問題。

## 啟動基線

```bash
ENGINE="$HOME/.cyder/runtime/Engines/wine-x86_64"
PREFIX="$HOME/pika-cyder-test"

WINEPREFIX="$PREFIX" \
WINESERVER="$ENGINE/bin/wineserver" \
PATH="$ENGINE/bin:$PATH" \
WINEMSYNC=0 WINEESYNC=0 \
arch -x86_64 "$ENGINE/bin/wine" \
  /path/to/皮卡丘打排球.exe
```

若由 Cyder 啟動，請在進階設定中關閉 MSync 與 ESync；兩者互斥，不能用同時開啟來測試「無同步」基線。

## 仍待釐清

- MSync／ESync 的失敗是否是遊戲自身對同步語意的依賴，或 CrossOver Wine 的 macOS 實作差異。
- 無空白 symlink 是否足夠，或必須是無空白的實體複製；原始詳細文件已列 E2／E3 驗證矩陣。
- runtime 路徑問題是否能由 Wine loader、`WINESERVER` 或 dylib relocation 修正；在確認前維持無空白實體 cache。

完整的路徑測試、排除項目與 Cyder 打包建議見 [cyder-engine-path-space-compatibility.md](../../cyder-engine-path-space-compatibility.md)。
