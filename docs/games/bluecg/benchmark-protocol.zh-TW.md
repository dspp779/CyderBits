# BlueCG 圖形效能、縮放與功耗對照

追蹤 [Issue #15](https://github.com/dspp779/CyderBits/issues/15)。此程序是待實機驗證的測試方法，並非已完成的效能或畫質結論。三開 CPU 約 160% → 50% 是使用者回報，不代表每個場景都會重現，也不能證明 GPU 讀回是原因。

## 已有能力與限制

- `scripts/run-bluecg.sh` 的 `--soft3d` 同時把 `3Ddevice:1` 換成 `3Ddevice:0` **並移除 `GAHD`**；它不是 renderer 開關，也不是只改一項的對照。主要實驗固定不使用它。
- `scripts/cyder-power-measure.sh` 可測 taskinfo、程序 energy impact，但只保留含 wine/wineserver 的 powermetrics 行，不能用來還原 CPU/GPU 晶片功率。`scripts/cyder-taskpolicy-benchmark.sh` 測 taskpolicy，會啟停程序，不能替代此互動式場景實驗。
- CompatDB 編譯器和格式支援 `actions.wined3d_renderer: gdi`，但 `compatdb/FORMAT.md` 同時寫明 standalone `cxcompatdb.so` **不套用此記錄**。因此 schema 支援不等於目前發佈的 runtime 已生效；須針對實際 engine 驗證，不能只依編譯通過宣稱支援。先不新增 BlueCG 規則。
- Wine 的 `WINE_D3D_CONFIG=renderer=gl` 與 `renderer=gdi` 是進程啟動時的候選指定；`gdi` 對應 WineD3D 的 no3d，並非遊戲內軟體運算選項。使用前須在實際 Wine 版本以短診斷確認有效；Cyder 私有 `CYDER_WINED3D_RENDERER` 若存在，優先於此設定。實際 DLL、載入路徑及選中 renderer 無法確認時，該組標為無效，不能根據環境變數直接下結論。[Wine 設定的上游說明](https://www.winehq.org/pipermail/wine-devel/2022-March/210420.html)

## 準備與隔離

1. 用已完成更新的遊戲資料副本與獨立 bottle；勿在原 bottle、遊戲目錄或其他遊戲共用 prefix 上做 registry／DLL 寫入。複製前正常退出該 bottle 的程序。記下原始設定，測試後保留或移除測試副本即可還原；不要全域終止共享 wineserver。先確認硬碟空間、遊戲授權與登入條件。
2. 記錄實際 Cyder app、Wine engine 版本與 hash、macOS／晶片、遊戲 EXE、launcher、資源檔版本與 hash、資料下載完成狀態、DDRAW.dll 來源和 hash、bottle 設定；固定啟動模式、`3Ddevice`、`GAHD`、Retina、DPI、顯示器解析度／縮放、視窗內容尺寸（points 與 pixels）、更新率、幀率上限及電源模式。不要假定只記 EXE hash 就代表所有資源相同。
3. 確定電源接法、電池狀態、低耗電模式、亮度、外接螢幕、背景負載、溫度／散熱狀態一致。記錄其他 Wine 程序；以同一獨立 prefix 的 wineserver 為準，不把其他 bottle 程序併入。測試資料含帳號、畫面和程序資訊，先保存在私有目錄，分享前去識別化。
4. 逐一核對遊戲視窗、`bluecg.exe` PID 與 wineserver PID；啟動器 PID 不能替代遊戲 PID。用短時間 `WINEDEBUG=+loaddll,+ddraw,+wined3d` 或同版本可用的診斷，確認實際載入的官方 shim、WineD3D 與 renderer；先驗證兩組 log 是否真能區分 renderer，若無法就如實記為未確認。正式取樣關閉大量 debug log。

## 每組啟動與還原

對**已隔離**的測試 prefix／遊戲副本，範例採直接啟動（測試前把佔位路徑換成自己的實際路徑）：

```sh
WINE_D3D_CONFIG='renderer=gl' bash scripts/run-bluecg.sh --prefix '/path/to/test-prefix' --game-dir '/path/to/test-game' --wine-install '/path/to/engine' --ddraw-source local --direct
# 下一組，完全退出上一組之後：
WINE_D3D_CONFIG='renderer=gdi' bash scripts/run-bluecg.sh --prefix '/path/to/test-prefix' --game-dir '/path/to/test-game' --wine-install '/path/to/engine' --ddraw-source local --direct
```

`--ddraw-source local` 要求副本已有欲測的 `ddraw.dll`，避免腳本複製或刪除 DLL。以上兩個範例不使用 `--soft3d`，變更只限於該次啟動繼承的環境；不要把它設成全域環境。若要透過官方 launcher 啟動，移除 `--direct`，並確認遊戲子程序繼承設定；launcher 自身也會繼承，仍以遊戲 PID 的實際證據為準。確認沒有衝突的 `CYDER_WINED3D_RENDERER`、CompatDB 規則或 DLL override；不要貼出完整環境變數。每輪正常退出所有測試程序並重新啟動；最後不帶此環境變數即可回到原設定。若原本本來就有 renderer override，記錄並保留原值；測試在新 shell 中進行。隔離副本內的遊戲自身設定及進度仍可能被遊戲寫入。

## 實驗矩陣與紀錄

先單開，再三開；各自做 **GL1 → GDI → GL2**。固定相同地圖、座標、視角、角色／寵物密度、天氣、動畫和視窗尺寸，先暖機 60 秒、測量 300 秒。三開要記錄每個視窗是否前景／遮擋；位置和遮擋次序每組一致，並分別指定每個遊戲 PID。每組記開始／結束時間及重新啟動後 PID。每組至少重複三輪，記錄順序與熱狀態；GL1 和 GL2 若飄移大於預先約定的容忍值（建議相對差 10%），視為環境不穩，不比較 GDI。非固定多人場景應記錄密度，無法重現則換可控制的場景。

分開進行省電模式實驗：先固定 renderer 完成一般模式 A/B/A，再固定同一 renderer 和場景做一般 → 省電 → 一般；如果使用的是 Cyder 的省電設定而非 macOS 低耗電模式，寫明名稱、實際政策及生效方式。不要同時切 renderer 和省電模式。若要研究交互作用，各 renderer 均完整做一遍省電 A/B/A。

每一 run 記錄：run ID、時間、單／三開、場景與版本、啟動參數、指定和**已確認** renderer、PID 對應、電源設定、視窗尺寸、暖機與採樣時長、場景異常、功率與幀時間資料來源、縮放截圖和失敗項。任何登入、切圖、程序退出、frame capture 丟失、測試焦點改變或系統壓力變化都標記；不完整 run 不參與排名。

### CPU

暖機後以明確核實的 PID 採 60 次、每次 5 秒（PID 僅為例子）：

```sh
python3 scripts/bluecg-benchmark.py cpu --pid game1=123 --pid game2=124 --pid game3=125 --pid wineserver=126 --interval 5 --samples 60 --output /private/tmp/bluecg-gl1-cpu.csv
```

單開只列一個 game。輸出以累積 CPU time 的差值除以實際經過時間，100% 代表一個核心，可超過 100%；CSV 含每個區間和每個 PID，取各區間平均及峰值、各遊戲與 wineserver，並加總相同區間估算總 CPU。`ps` 解析度可能粗糙；程序消失或 PID 身份改變時工具報錯停止並留下部分 CSV，該 run 無效，不自動重選 PID。核對 wineserver 是否專屬測試 prefix；計量不含未指定的其他程序。使用者先前的 160%／50% 可能包含不同程序，沒有相同口徑時不能直接相比。

### 幀時間

使用**能在 DirectDraw / WineD3D GL 與 GDI 兩條路徑上提供相同定義的逐次呈現時間戳**的工具；每個遊戲各自取樣、保持相同採集方式與開銷。先在兩條路徑驗證事件是否確實對應遊戲呈現、有無重複／遺失及 timestamp 單位；DXVK HUD 不適用於 WineD3D。一般螢幕錄影可能固定幀率、重複或漏掉畫面，不能直接當成遊戲呈現幀時間。若沒有經驗證的資料源，標記「幀時間未測」，不能宣稱卡頓改善。

把連續呈現 timestamp 差值換成毫秒，依時間先後輸出單欄 CSV（標題 `frame_ms`，每列為正的間隔；不得跨程序、跨錄製中斷）。分別分析各遊戲：

```sh
python3 scripts/bluecg-benchmark.py frames /private/tmp/bluecg-gl1-frames.csv --long-ms 50
```

輸出中位數、nearest-rank P95/P99、嚴格大於 50 ms 的長幀次數與樣本數；所有 run 使用同一定義、門檻與時長，同時報每分鐘長幀。門檻是預設報告尺度，不預設遊戲目標幀率；可另外報與固定目標幀率相關的門檻。列出採樣盲區與工具開銷，不以 FPS 倒數或 CPU 估算幀時間。

### 功率與能量

在正式取樣同時，從終端機手動啟動（需要系統管理員驗證；支援與欄位依機型／macOS 而異）：

```sh
sudo powermetrics --samplers cpu_power,gpu_power,tasks --show-process-energy -i 5000 -n 60 > /private/tmp/bluecg-gl1-power.txt
```

記錄實際開始／結束時間，使用與 CPU 相同的 300 秒窗口；保留完整原始輸出及缺欄／錯誤，不要套用只留 wine 行的篩選。比較同機同電源條件下 CPU、GPU 及可用的 combined 功率各自的平均 mW 與波動；只可把實際標示 mW 的同一功率欄位乘每個採樣秒數、除以 1000 得到估計 J。若最後區間不完整，使用實際區間，或排除並註記。不要把 CPU、GPU、combined 加總而重複計數；不能把程序 Energy Impact 當瓦特／焦耳，也不能將整機／晶片功率歸給單一程序。這些是估計值，不是插座實測或跨機比較；功率欄位不存在時如實記錄，不能換用 Energy Impact 冒充功耗。驗證採集對效能的影響並固定在所有組，記錄環境溫度及熱節流。

### 縮放與畫面

每組同場景先在原尺寸截圖，再以固定的視窗內容尺寸測 1×、1.5×、2×（顯示器／Retina 的 point 與實際像素比例分開記），使用相同字串、字型、UI、顏色、OS 截圖方式與螢幕，保持原始像素，不縮圖、不經聊天壓縮。放大前後比較 GL1、GDI、GL2 的字體筆畫斷裂、鋸齒／模糊、重疊、透明動畫、裁切、色彩與游標。記錄每個尺寸可讀性、破字／位置、截圖路徑，並測拖曳後、Alt+Enter、最小化／還原。GL 正常而 GDI 破字是既有回報，須在此版本重測；縮放演算法是候選原因，不應在未確認濾鏡與實際路徑時認定根因。

## 判讀與後續

只有同場景重複 A/B/A 穩定、幀時間與長幀改善、逐程序 CPU 與功率有可比資料、縮放字體及功能可接受，才考慮 `bluecg.exe` 限定規則。若效能提升但字體破碎，視為畫質未通過，保留 GL 預設並另行追蹤；若只降低 CPU 或沒有幀時間，不能稱已解決卡頓。規則先確認實際 engine 支援、增加匹配與排除測試，並準備停用規則／移除自訂 override 回復原值的方式；不能改其他遊戲預設。尚無實測結果時保留此狀態，不推斷特定更新或 GPU 讀回為根因。
