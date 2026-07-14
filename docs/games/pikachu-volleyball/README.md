# 皮卡丘打排球

## 問題索引

| 問題 | 狀態 | 文件 |
|------|------|------|
| MSync | **已知不相容**；開啟後無法正常運作 | [runtime path／sync 相容性](runtime-path-and-sync.md) |
| ESync | **已知不相容**；開啟後無法正常運作 | [runtime path／sync 相容性](runtime-path-and-sync.md) |
| Wine runtime 路徑含空白 | **已知不相容**；含 `Application Support` 的實際 engine 路徑會在 demo 模式附近 page fault | [詳細調查](../../cyder-engine-path-space-compatibility.md) |

## 目前 workaround

使用不含空白的 Wine runtime 實體路徑，並以 MSync、ESync 都關閉的設定作為遊戲基線。Cyder 的正式 runtime 位置是：

```text
~/.cyder/runtime/Engines/wine-x86_64
```

設定與 bottle 可以留在 `~/Library/Application Support/Cyder/`；不要把可執行 runtime 實體放回含空白的 `Engines/` 路徑。啟動時仍須讓 `WINEPREFIX`、`WINESERVER` 與 `PATH` 指向同一份 engine。

這是目前的相容性 workaround，不代表已定位 Wine loader／CrossOver runtime 的根因。
