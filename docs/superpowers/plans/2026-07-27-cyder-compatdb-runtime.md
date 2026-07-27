# Cyder CompatDB Runtime 開發計劃

日期：2026-07-27

## 目標

將目前寫死在 Wine `kernelbase` 的 Steam WebHelper 相容性修補泛化為可更新的
Cyder CompatDB。新增或修正規則時只需發布資料庫，不需重新編譯 Wine、重包
engine 或重建 bottle。

YAML 是規則的 authoring format；Wine runtime 不直接解析 YAML。開發工具會先
驗證 YAML、執行 rule fixtures，再輸出 versioned、bounded、可略過未知 record
的 CDB runtime 格式。

## 非目標

- 不複製或散布 CrossOver 的 proprietary `cxcompatdb.so` 或資料庫。
- 不提供任意 shell command、任意 dylib 載入或一般 regex。
- 第一版不提供線上更新服務或 UI；只完成可安全更新的資料與 runtime 邊界。
- 第一版不一次啟用所有已觀察到的 CrossOver 規則。

## 穩定邊界

```text
compatdb/rules/*.yml
        │
        ▼
cyder-compatdb compiler ── schema/lint/fixtures
        │
        ▼
content-addressed compatdb.cdb
        │  CYDER_COMPATDB_PATH
        ▼
ntdll NtCreateUserProcess
        │
        ▼
path/cmdline/environment → typed actions → child process
```

### Authoring schema

- `schema_version`
- 全域唯一且穩定的 rule `id`
- 明確的 `priority`
- `applies_to` capability / platform gate
- 非遞迴、可預測的 match 結構
- typed actions
- 每條啟用規則至少一個 positive fixture
- 有排除條件的規則至少一個 negative fixture

同一 match 物件內的不同 predicate 是 AND；同一 predicate 的值陣列是 OR。
不支援任意遞迴布林運算。

### Runtime CDB

CDB v1 使用 little-endian header 與 length-prefixed TLV records：

- 固定 magic 與 format version
- 宣告總長度、record 數與 rule 數
- 每個 record 都有 type、flags、length
- 未知且非 required 的 record 可依 length 安全跳過
- required 但未知的 record 使該 rule 無效，不使 process creation 失敗
- parser 設定檔案、rule、record、字串與 action 數上限
- runtime parser 不配置未受限制的記憶體

第一版 record：

- rule begin/end、ID、priority
- executable path suffix
- forbidden command-line token
- append argument token
- process-local DLL override
- set/unset process environment
- process-local graphics backend
- executable suffix replacement

格式預留但可分期實作：

- Steam App ID
- required argument token
- environment predicate

### Wine API

argv action 的 hook 位於 `dlls/ntdll/unix/process.c::NtCreateUserProcess`；
DLL override 在目標程序的 loader 初始化階段套用。CompatDB helper：

- fail open；資料庫缺失、無效或配置失敗時保留原始程序參數
- 不直接修改 caller-owned buffers
- 回傳自有的 image path、command line、environment replacements
- 同步維護 `RTL_USER_PROCESS_PARAMETERS` 與 `PS_ATTRIBUTE_IMAGE_NAME`
- 使用 Windows case-insensitive path suffix matching
- 使用 Windows command-line tokenization 與 quoting
- append argument 依 option key 去重
- DLL override 直接加入 process-local load-order list，不修改 Registry 或
  繼承式環境變數
- 透過 `+cydercompat` 記錄 database version、命中 rule ID 與 action，不記錄敏感環境值

## 規則分層與 session 一致性

1. App 內 bundled last-known-good CDB
2. 官方簽署的完整 update snapshot
3. 明確開啟 developer mode 才允許本地 unsigned override

Compiler 依內容 hash 產生不可變路徑：

```text
~/.cyder/runtime/CompatDB/<sha256>/compatdb.cdb
```

Cyder 啟動一個 Wine session 時設定固定的 `CYDER_COMPATDB_PATH`。該 session
產生的所有子程序繼承同一路徑；資料庫更新只影響下一個 session，避免同一
wineserver 內混用兩版規則。

## 規則衝突

- 多條規則可同時命中，排序為 layer、priority、rule ID。
- append args 保持穩定順序並依 option key 去重。
- environment 與 DLL override 依 key 由較高 priority 覆蓋。
- graphics backend 與 executable replacement 是 exclusive action。
- 相同 priority 的 exclusive conflict 必須由 compiler 拒絕。
- 官方 update 使用相同 ID 取代 bundled rule，不以檔案順序覆寫。

## 開發階段

### Phase A — Data toolchain

- 建立 YAML schema、compiler、CDB v1 encoder/decoder。
- 建立 lint、positive/negative fixture runner 與 deterministic output test。
- 將 Steam WebHelper 規則作為第一條正式規則。
- App 打包 bundled CDB；launcher 選定 content-addressed session path。

驗收：

- 同一份 YAML 每次產生 byte-identical CDB。
- malformed YAML/schema/TLV、重複 ID、衝突 action 全部有負向測試。
- 修改 YAML 後不需要執行 Wine build。

### Phase B — Wine runtime

- 新增 CDB bounded parser 與 process-rule matcher。
- 在 `NtCreateUserProcess` 加入單一 hook。
- 實作 path suffix、forbidden token、append args 與 opt-out。
- Wine build 改套用通用 compatdb patch，不再套用 Steam hard-code patch。

驗收：

- Steam renderer WebHelper 得到三個已驗證參數。
- crashpad-handler 不得到參數。
- 非 Steam exe 完全不變。
- 缺檔、截斷、未知 optional TLV、未知 required TLV 全部 fail open。
- command line quoting、Unicode path、大小寫與重複參數有 unit tests。

### Phase C — Integration

- 與現有 Cyder CLI、原生 app 與直接 Wine 指令路徑整合。
- 確認 engine artifact 與 app payload 都包含 bundled CDB。
- 保留 `CYDER_COMPATDB=0` 與 content-addressed A/B 測試方式。
- 用現有 Steam bottle 做 direct Wine 驗證。

### Phase D — Review

由未參與實作的 reviewer 檢查：

- process-creation buffer ownership、錯誤路徑與 cleanup
- parser bounds、integer overflow、unknown-record behavior
- Windows path、argv 與 environment semantics
- 規則衝突與 deterministic compiler
- app packaging、簽署邊界與 session 一致性
- 既有 Steam、launcher、engine artifact 測試回歸

Review 發現必須修正或明確記錄為後續工作，才能移除舊 Steam hard-code。

## 工作分配

| 工作流 | Owner | 主要輸出 |
|---|---|---|
| Data toolchain | compatdb-data subagent | schema、YAML、compiler、CDB fixtures/tests |
| Wine runtime | wine-runtime subagent | ntdll patch、CDB reader/matcher、Wine-side tests |
| Integration | primary agent | build/app/launcher 整合、repo tests、實機驗證 |
| Independent review | reviewer subagent | findings、風險分級、必要修正與再驗證 |

## 完成條件

- 新增規則只需修改 YAML 並重新產生／發布 CDB。
- Wine engine 不包含任何 Steam executable hard-code。
- Steam UI 維持可見，crashpad 不誤套規則。
- 所有 repo 測試及 CompatDB 專屬負向測試通過。
- reviewer 沒有未處理的高風險 correctness 或 security finding。

## 執行狀態

- Phase A data toolchain：已完成。
- Phase B Wine runtime MVP：已完成；tracked verifier 會將 patch 套入實際
  CrossOver Wine source、編譯 x86_64 ntdll/kernelbase，並實跑 renderer、
  crashpad、opt-out、去重、Unicode quoting、未知 TLV、截斷 CDB 與重複 ID。
- Phase C integration：已完成；CLI 與原生 App 使用相同的 bundled/update/
  developer override 選擇順序，並以 bottle pin 固定同一 wineserver session
  的 CDB。
- Phase D independent review：已完成；三輪 closure review 後沒有未處理的
  P0/P1/P2 finding，可進入實機 A/B 與 release integration。

### 第一輪 review 修正

| Finding | 處理 |
|---|---|
| update 目錄未驗證內容 hash、override 無 gate | 驗證 CDB SHA-256 必須等於目錄名；外部 CDB 僅在 `CYDER_COMPATDB_ALLOW_UNSIGNED=1` 可用 |
| 同一 wineserver 可能混用不同 CDB | 在 bottle 的 `.cyder-runtime/compatdb.path` 固定 active session |
| Wine 測試只有 patch 文字／dry-run | 新增會實際 patch、build、run、restore 的 tracked verifier |
| App 可能封裝舊 compiled CDB | 打包時直接從 YAML fresh compile 並 inspect |
| compiler/runtime Unicode case 語意不同 | CDB v1 executable suffix 限制為 printable ASCII |
| duplicate rule ID 處理不同 | compiler/inspector/runtime 一律把整份 CDB 判為結構無效 |

第二輪發現的 external override/pin digest 缺口與 fresh-prefix 首次 pin 時機也已
關閉：unsigned external 必須同時提供 developer gate 與 expected SHA-256，
structured pin 每次讀取都重新驗證；CLI 會在 prefix 建立後、實際 launch 前
再次 ensure pin。Swift wineserver detection 也要求路徑確實是 Unix socket。

官方簽章線上更新器仍屬後續階段，未包含在 v1。正式模式只信任隨 App
code-sign 的 bundled CDB；content-addressed 外部 snapshot 是明確開啟的
unsigned developer 功能，不宣稱是官方更新通道。
