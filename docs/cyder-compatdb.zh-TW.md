# Cyder CompatDB：相容性規則維護指南

Cyder CompatDB 將特定 Windows 程式需要的相容參數從 Wine 原始碼移到
YAML 規則。Wine runtime 只實作通用的「匹配程序、執行受限制動作」能力，
不包含 `steamwebhelper.exe` 等特定程式名稱。

目前第一條正式規則用於修正 Steam WebHelper 黑畫面：

```text
YAML 規則
  → validate / fixtures
  → compile
  → compatdb.cdb
  → Wine process runtime
  → 匹配 exe 並追加 argv 或套用 process-local DLL override
```

## 這次需要重包 Engine 嗎？

**需要，必須重包一次。**

既有 Engine 沒有通用 CompatDB parser 與 `NtCreateUserProcess` hook，只更新
Cyder App 或放入 YAML/CDB 不會生效。第一次發布此功能時需要：

1. 重新編譯 Wine，讓 `scripts/build-wine.sh` 套用
   `patches/cyder-compatdb-runtime.patch`。
2. 將新的 Wine install tree 重包成 Engine artifact。
3. 以新 Engine artifact 建立 Cyder App；打包流程會從 YAML 重新編譯內建
   `CompatDB/compatdb.cdb`。
4. 使用不同 Engine version 發布，讓已安裝的舊 Engine 能被正確升級。

典型流程：

```bash
bash scripts/build-wine.sh --cx 26

# 請設定新的 CYDER_ENGINE_VERSION，避免沿用已安裝版本。
CYDER_ENGINE_VERSION='wine crossover 26.3.0 (wine 11.0) Cyder005' \
  bash scripts/pack-engine-artifact.sh --force

bash scripts/create-cyder-app.sh \
  --engine-archive /path/to/new-engine.tar.xz
```

實際版本名稱與 artifact 路徑應依當次 release 設定調整，不要覆寫既有
Cyder004 artifact。

### 之後哪些變更不需要重包 Engine？

已安裝通用 CompatDB Engine 後，下列變更只需要重新產生 CDB：

- 新增另一個 exe 的規則。
- 修改 path suffix。
- 新增或移除禁止命中的命令列 token。
- 修改需要追加的參數。
- 新增或修改任何 Engine 已支援的 action。
- 啟用、停用或調整既有規則 priority。

如果 CDB 隨 App 發布，仍需重建／重新簽署 Cyder App，但**不必重新編譯或
重包 Engine**。未來完成簽章更新器後，CDB 可獨立發布，連 App 都不必重包。

下列變更仍需要重新編譯及重包 Engine：

- 新增 v1 尚未支援的 matcher，例如環境變數、Steam App ID 或 parent process。
- 新增 v1 尚未支援的新 action 類型。
- 變更 CDB binary format 或 `engine_api`。
- 修正 Wine runtime parser、argv quoting 或 process hook 本身。

## 可以自行加入 YAML 規則嗎？

**可以，但只能使用 Engine 已支援的 matcher 與 action。** YAML 不是任意
command hook，也不能執行 shell、載入任意 dylib 或寫入任意 Wine 設定。

CDB v1 目前支援：

| 類型 | YAML | 語意 |
|---|---|---|
| Match | `match.executable.path_suffix` | 以 Windows exe 完整路徑尾端比對；ASCII case-insensitive |
| Match | `match.command_line.excludes[].token` | argv 中出現指定完整 token 時排除規則 |
| Action | `actions.append_args.args[]` | 追加完整 argv token；runtime 負責 Windows quoting |
| Action | `actions.dll_overrides.<module>` | 對命中的程序套用 process-local Wine DLL load order |
| Action | `actions.set_env.<name>` | 設定目標程序的 Windows environment value |
| Action | `actions.unset_env[]` | 從目標程序移除 environment name |
| Action | `actions.graphics_backend` | process-local 選擇 `default`、`wined3d`、`dxvk`、`dxvk2`、`dxmt` 或 `d3dmetal` |
| Action | `actions.wined3d_renderer` | WineD3D 內部選擇 `auto`、`opengl`、`gdi` 或 `vulkan` |
| Action | `actions.replace_executable.path_suffix` | 開啟 PE 前安全替換 executable suffix 與 argv[0] |
| Action policy | `deduplicate: option` | 依 option key 去重，不覆寫呼叫端已提供的值 |

同一規則的不同 predicate 採 AND；多個 `path_suffix` 是 OR。v1 的
`path_suffix` 必須：

- 使用 Windows 反斜線並以 `\` 開頭。
- 僅使用 printable ASCII。
- 不使用 glob、regex 或只比對模糊 basename。

規則依 priority 由高至低套用。環境變數與 DLL override 以 key 為單位由
第一個命中的高 priority action 勝出；相同 priority 的矛盾會在編譯時
拒絕。`replace_executable` 必須是該規則唯一的 action，替換後程序需要的
其他動作應寫在另一條匹配目標 EXE 的規則。

完整 action 範例：

```yaml
actions:
  append_args:
    args: ['--compat-mode']
    deduplicate: option
  set_env:
    GAME_RENDER_MODE: compatibility
  unset_env:
    - GAME_UNSAFE_FEATURE
  dll_overrides:
    ddraw: native,builtin
  graphics_backend: wined3d
  wined3d_renderer: opengl
```

`graphics_backend` 是整套 Direct3D translation stack；未填寫時採預設選擇，
明確填寫 `default` 則會阻止較低 priority 的 backend 規則，並回到 Engine
安全預設（目前是 WineD3D）。Engine 只會從自己的 payload root 尋找：

| 值 | 需要的 Engine payload |
|---|---|
| `wined3d` | Wine 內建 DLL，不需額外 payload |
| `dxvk` | `lib/dxvk/<arch>-windows/` 與 Engine 內的 MoltenVK |
| `dxvk2` | `lib/dxvk2/<arch>-windows/` 與 Engine 內的 MoltenVK |
| `dxmt` | `lib/dxmt/<arch>-windows/` 與 `x86_64-unix/winemetal.so` |
| `d3dmetal` | `lib64/apple_gptk/wine/<arch>-windows/`、`libd3dshared.dylib` 與 `D3DMetal.framework` |

DXVK 的 DLL 是原生 Windows 模組。Cyder 在 bottle bootstrap 時，從 Engine
同步 `d3d11.dll` 與 `dxgi.dll` 到 `system32/syswow64`；只有匹配
`graphics_backend: dxvk` 的程序才會套用 `native,builtin`。未匹配程序仍以
`builtin` 使用 WineD3D，因此同一個 bottle 可以按 EXE 選擇 backend。
CrossOver 25.0.1 FOSS snapshot（DXVK 1.10.3）與上游 2.7.1 的編譯步驟、目錄
（`lib/dxvk` vs `lib/dxvk2`）與 llvm-mingw 補丁見
[DXVK 編譯備忘](build-dxvk.zh-TW.md)。

缺少目前程序架構可用的 DLL 時會記錄診斷並回退 WineD3D，不會跨 App
搜尋或借用 `/Applications/CrossOver.app` 的檔案。這使規則可以自由匯出，
而 backend 的授權、簽署及版本相容性仍由 Engine payload 負責。

### D3DMetal 並不是 macOS 自動提供

CrossOver 的實際機制是由 CompatDB 選到 `d3dmetal` 後，將
`lib64/apple_gptk/wine` 加到 Wine DLL 搜尋路徑，對存在的 D3D DLL 套用
process-local builtin override，並以
`CX_APPLEGPTK_LIBD3DSHARED_PATH` 指向
`lib64/apple_gptk/external/libd3dshared.dylib`。因此不是呼叫某個系統 API
就會自動取得 GPTK；仍需要一份合法取得且完整的 Apple GPTK runtime。

Cyder 支援相同的 payload layout，但不會把 Apple runtime 納入原始碼庫，
也不會自動複製 CrossOver 的檔案。若 Engine 建置或使用者安裝流程合法地
提供該 payload，`graphics_backend: d3dmetal` 即可 process-local 啟用。
看到 Metal HUD 只能證明程序使用 Metal；D3DMetal、DXMT、MoltenVK，甚至
其他 Metal layer 都可能觸發 HUD，不能單靠 HUD 判定 backend。

EXE replacement 需獨立成規則：

```yaml
actions:
  replace_executable:
    path_suffix: '\bin\replacement.exe'
```

環境變數名稱不分大小寫並正規化為大寫。為避免設定檔改變 host loader 或
Cyder session，`PATH`、`HOME`、`WINEPREFIX`、`WINELOADER`、`WINESERVER`、
`CYDER_*`、`DYLD_*` 與 `LD_*` 不允許由規則設定或移除。

## 新增規則

可以修改 `compatdb/rules/steam.yml`，也可以在 `compatdb/rules/` 新增另一個
`.yml`。每份檔案都使用 `schema_version: 1`；所有檔案的 rule ID 必須全域
唯一。

最小範例：

```yaml
schema_version: 1

rules:
  - id: launcher.example.client.renderer
    description: Add the verified renderer switch for Example Client.
    priority: 100
    enabled: true
    stability: experimental

    applies_to:
      platform: macos
      engine_api: 1

    match:
      executable:
        path_suffix: '\examplehelper.exe'
      command_line:
        excludes:
          - token: '--type=crash-handler'

    actions:
      append_args:
        args:
          - '--verified-renderer-switch'
        deduplicate: option

    tests:
      matches:
        - name: renderer receives the switch
          executable: 'C:\Program Files\Example\examplehelper.exe'
          command_line:
            - examplehelper.exe
            - '--type=renderer'
      excludes:
        - name: crash handler remains untouched
          executable: 'C:\Program Files\Example\examplehelper.exe'
          command_line:
            - examplehelper.exe
            - '--type=crash-handler'
        - name: unrelated program remains untouched
          executable: 'C:\Games\Other\game.exe'
          command_line:
            - game.exe
```

建議先以 `stability: experimental` 開發，完成 direct Wine、Cyder App、
positive fixture 與 negative fixture 驗證後才改成 `stable`。

## 指定 EXE 使用 cnc-ddraw

這需要兩個互補步驟：

1. 將已驗證的 `ddraw.dll`、`ddraw.ini` 與 `Shaders/` 安裝到目標 EXE
   所在目錄。
2. 以 CompatDB 只對該 EXE 套用 `ddraw: native,builtin`。

例如：

```yaml
schema_version: 1

rules:
  - id: game.example.cnc-ddraw
    description: Use the provisioned cnc-ddraw renderer for Example Game.
    priority: 100
    enabled: true
    stability: experimental

    applies_to:
      platform: macos
      engine_api: 1

    match:
      executable:
        path_suffix: '\game.exe'

    actions:
      dll_overrides:
        ddraw: native,builtin

    tests:
      matches:
        - name: target game receives the override
          executable: 'C:\Games\Example\game.exe'
          command_line: [game.exe]
      excludes:
        - name: unrelated executable is unaffected
          executable: 'C:\Games\Other\other.exe'
          command_line: [other.exe]
```

`native,builtin` 在 CDB 中正規化為 Wine 的 `n,b`。runtime 直接寫入該
程序的 in-memory DLL load-order list，不修改 bottle Registry，也不把
`WINEDLLOVERRIDES` 傳給其他子程序。

Cyder 目前內建 cnc-ddraw 7.1.0.0 的固定離線 payload。以大富翁 4 為例：

```bash
scripts/cyder-recipe.sh apply recipes/defaults.json richman-4 \
  "$WINEPREFIX" "/path/to/Richman 4/rich4.exe"
```

此命令驗證 archive SHA-256 後，只解出 `ddraw.dll`、`ddraw.ini` 與
`Shaders/`；不安裝設定 GUI，也不覆蓋既有同名檔案。解除安裝只會刪除
內容未被使用者修改的受管檔案。`compatdb/rules/games.yml` 已包含
`rich4.exe` 的 DLL override 規則。

## 驗證與編譯

工具需要 Python 3 與 PyYAML：

```bash
python3 -m pip install -r requirements-compatdb.txt
```

驗證所有 YAML 與內建 fixtures：

```bash
python3 scripts/cyder-compatdb.py validate compatdb/rules
```

產生 deterministic CDB 並再次解析檢查：

```bash
python3 scripts/cyder-compatdb.py compile \
  compatdb/rules \
  -o compatdb/compiled/compatdb.cdb

python3 scripts/cyder-compatdb.py inspect \
  compatdb/compiled/compatdb.cdb
```

執行相關自動測試：

```bash
bash tests/test-cyder-compatdb-data.sh
bash tests/test-cyder-compatdb-integration.sh
bash tests/test-cyder-compatdb-wine-runtime.sh
```

要實際套 patch、編譯 ntdll/kernelbase 並啟動測試 exe：

```bash
bash tests/verify-cyder-compatdb-wine-runtime.sh
```

此 verifier 需要現有的 CrossOver Wine source/build tree，而且會啟動本機
Wine/wineserver。完成後會將 source tree 還原成測試前狀態。

## 本機測試新 CDB，不重包 App

外部 CDB 是 developer-only 功能，必須明確開啟並驗證 SHA-256。最簡單的
單次測試方式：

```bash
DB="$PWD/compatdb/compiled/compatdb.cdb"
DB_SHA256="$(shasum -a 256 "$DB" | awk '{print $1}')"

CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
CYDER_COMPATDB_PATH="$DB" \
CYDER_COMPATDB_SHA256="$DB_SHA256" \
  bash scripts/cyder_launcher.sh /path/to/program.exe
```

也可以使用 content-addressed layout：

```text
~/.cyder/runtime/CompatDB/<sha256>/compatdb.cdb
~/.cyder/runtime/CompatDB/current
```

`current` 的內容是 64 字元 SHA-256。啟動時仍需設定
`CYDER_COMPATDB_ALLOW_UNSIGNED=1`；Cyder 會確認目錄名稱和實際檔案 hash
一致。同一個 wineserver session 會將已選版本固定在 bottle 的：

```text
<prefix>/.cyder-runtime/compatdb.path
```

不要在 Wine session 執行期間修改該檔案或切換 `current`。更新只應影響下一個
session。可設定 `CYDER_COMPATDB=0` 做完全停用的 A/B 對照。

## 發布方式

目前正式模式只信任隨 Cyder App code-sign 的 bundled CDB：

```text
Cyder.app/Contents/Resources/CompatDB/compatdb.cdb
```

`scripts/create-cyder-app.sh` 每次都會從 `compatdb/rules/` fresh compile 並
inspect，不會直接複製可能過期的 compiled 檔案。

目前尚未實作官方簽章 CDB updater。因此：

| 情境 | Engine | Cyder App | CDB |
|---|---|---|---|
| 首次導入 CompatDB runtime | 重編、重包、升版 | 重包 | 內建 |
| 只修改既有 v1 規則 | 不變 | 正式發布時重包 | 重新編譯 |
| 本機開發／A-B | 不變 | 不變 | unsigned + gate + SHA-256 |
| 新增 matcher/action/runtime 能力 | 重編、重包、升版 | 重包 | 重新編譯 |
| 未來簽章 CDB updater | 不變 | 視 updater 實作而定 | 可獨立發布 |

## 安全與維護原則

- 每條啟用規則至少要有一個 positive fixture。
- 有排除條件時至少要有一個 negative fixture。
- 比對範圍要盡量精確，避免對常見的 `helper.exe` 或 `game.exe` 全域套用。
- 一個 action token 只放一個 argv，不要自行拼接含空白的 command fragment。
- 不確定的規則保持 `experimental` 或 `enabled: false`。
- Steam client 的 `-system-composer` 規則目前仍是 disabled experimental；
  在所有啟動路徑完成回歸前，既有 launcher 行為仍保留。
- CDB 無效時 Wine runtime 會 fail open，保留原始程序參數。

Binary layout、bounds、TLV 與 unknown-record 行為的正式契約見
[`compatdb/FORMAT.md`](../compatdb/FORMAT.md)。開發分期與 review 結果見
[`docs/superpowers/plans/2026-07-27-cyder-compatdb-runtime.md`](superpowers/plans/2026-07-27-cyder-compatdb-runtime.md)。
