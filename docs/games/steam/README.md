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

## 偏好設定的圖形選 DXVK 時 Steam 不出現視窗

偏好設定 > 圖形若選 **DXVK**，Steam 會在背景執行，但登入視窗與主視窗都不會出現
（WebHelper 的子程序約 15 秒後結束，沒有任何頁面）。

原因：全域圖形選項會套用到 Cyder 啟動的每個程序，包括 `steamwebhelper.exe`。
engine 的 CompatDB 讓使用者選的圖形（`CYDER_GRAPHICS_BACKEND`）優先於所有規則，
所以不能用規則把 WebHelper 固定在 WineD3D。

處理方式（擇一）：

- 偏好設定 > 圖形選「預設」。
- 只把 Steam 這一項的圖形設為 WineD3D（或預設），其他遊戲另外指定 DXVK。

2026-11-15 在 macOS 27.2、Apple M4、engine Cyder013 以同一份 Steam 檔案對照：

| 條件 | Steam 視窗 |
|---|---|
| 圖形 = DXVK（Cyder 啟動或直接強制） | 不出現（3 次） |
| 圖形 = WineD3D，全新 prefix | 登入畫面正常 |
| 圖形 = WineD3D，原本的 shared bottle | 主視窗正常，可登入與下載 |
| 圖形 = DXVK，加上 WebHelper 指定 `graphics_backend: wined3d` 的規則 | 不出現：規則被全域設定蓋過 |

每種條件各測 1 次；DXVK 失敗一致重現。沒有追查 DXVK 為何會讓 WebHelper 停住。

從 Steam 內啟動的遊戲會繼承 Steam 的圖形設定。需要 DXMT／DXVK 的遊戲，
建議保持 Steam 在背景，再從 Cyder 直接開啟遊戲執行檔並在該遊戲設定圖形。

### 其他工具的做法

| 來源 | WebHelper 處理 |
|---|---|
| Cyder CompatDB | `--no-sandbox --in-process-gpu --disable-gpu`（排除 crashpad） |
| GameHub（GameSir Wine） | `--no-sandbox --single-process --disable-gpu` |
| GameToMac 0.1.5（Wine 原始碼） | 預設不改；`AOELAB_STEAM_SINGLEPROCESS=1` 時只對 browser 程序加 `--disable-gpu --single-process` |
| sommelier `steam-webhelper-v1` | winmm.dll proxy，只對 browser 程序加 `--in-process-gpu` |
| CrossOver | 規則在封閉的 `cxcompatdb.so`／資料庫內，本機無法確認；圖形選「Auto」時依資料庫逐程式選擇 |
