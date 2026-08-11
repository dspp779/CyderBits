# Steam

Cyder 對 `Steam.exe` 套用 macOS/Wine 專用的啟動相容設定：

- `-system-composer`：避開 CEF 子視窗 compositor 畫面未呈現、但 DOM 仍可互動的黑畫面路徑。
- `-no-cef-sandbox`：停用 Wine 無法完整提供的 Chromium Windows sandbox。

此外，Cyder engine 在建立 `steamwebhelper.exe` 時會直接追加：

- `--no-sandbox`
- `--in-process-gpu`
- `--disable-gpu`

這一層不能只靠 `Steam.exe -cef-*` 參數取代。新版 Steam 不會把
`-cef-in-process-gpu` 轉交給 64 位元 WebHelper；獨立 GPU process 會在
Wine/macOS 建立無效的 Skia output surface，連續崩潰後留下黑畫面。Cyder
透過 `compatdb/rules/steam.yml` 宣告規則，再由 engine 內的開放原始碼
`cxcompatdb.so` 經 CrossOver 原有 loader hook 套用。原始 CrossOver ntdll
不需要 Cyder patch。
規則更新只需要重新產生 CompatDB，不需重新編譯 Wine。
新增或維護 YAML 規則、Engine 重包時機與本機 CDB 測試方式，見
[Cyder CompatDB 維護指南](../../cyder-compatdb.zh-TW.md)。

相容參數會保留既有的 Steam 啟動參數，且不重複加入。若要做 A/B
測試，可在該執行檔的環境變數中設定：

```text
CYDER_STEAM_COMPAT=0
```

這只會停用 `Steam.exe` 的 launcher 自動參數。若要停用 engine 內所有
CompatDB 規則，可設定：

```text
CYDER_COMPATDB=0
```

目前 engine 已內含 CrossOver Wine 的 MoltenVK runtime，並直接載入
`libMoltenVK.dylib`；Steam 黑畫面不應以「缺少 Vulkan Loader」作為已確認
根因。DXVK 尚未成為 Cyder 的預設圖形路徑，個別 Windows 遊戲的相容性仍需
逐款驗證。
