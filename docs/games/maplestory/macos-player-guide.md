# 在 macOS 玩台灣楓之谷（玩家教學）

最後更新：2026-07-21

本教學依實際可玩流程整理，目標是讓一般玩家能在 Apple Silicon／Intel Mac 上安裝並啟動**台灣版**楓之谷。這不是官方支援路徑，遊戲與登入服務隨時可能變更。

## 你會用到什麼

| 項目 | 用途 |
| --- | --- |
| 美版 [MapleStory Launcher](https://www.nexon.com/maplestory/) | 提供 Nexon／CodeWeavers 客製的 Wine（CrossOver OEM）與 bottle |
| [gamania Games Manager](https://tw.beanfun.com/ggm/index.html) | 下載／安裝台版楓之谷；安裝過程可能要求 .NET 6 |
| [CitrusGate](https://github.com/dspp779/CitrusGate) | 取得 Beanfun 帳號 ID 與 OTP，並組出完整啟動指令 |
| Beanfun 帳號 | 台版登入憑證來源 |

研究細節（OEM engine、Cyder、防作弊 lifecycle）見同目錄其他文件；一般遊玩不必閱讀。

## 注意事項（請先看）

1. **安裝路徑請選好找的地方**  
   管理器與遊戲若裝進 bottle 的 `Program Files`，之後很難在 Finder 找到。建議都裝到 macOS「文件」底下，例如：
   - 管理器：`~/Documents/ogs/ggm`
   - 遊戲：`~/Documents/ogs/gamania Games/MapleStory`  
   Wine 的「我的文件」通常對應你的 macOS `Documents`，選 Documents／文件即可。

2. **啟動參數必須是帳號 ID + OTP**  
   遊戲命令列需要 `ServiceAccountID`（形如 `T9...`）與短期 OTP。  
   **不要**把 Beanfun 顯示名稱或純數字 SN 當成帳號 ID，否則可能畫面正常卻顯示「未登錄的帳號」。

3. **OTP 很快過期**  
   請在取得後立刻啟動；不要把 OTP 寫進長期筆記或分享出去。

4. **Apple Silicon 需要 Rosetta**  
   美版 Launcher 內的 Wine 是 x86_64。若系統尚未安裝 Rosetta，首次開啟相關程式時依提示安裝即可。

5. **繁體中文環境**  
   台版會檢查繁中 code page。下方指令會設定 `zh_TW.UTF-8`；若出現 Traditional Chinese／code-page 相關錯誤，請確認這三個變數都有設上。

---

## 步驟 0：準備目錄（建議）

在「終端機」執行：

```sh
mkdir -p "$HOME/Documents/ogs"
```

之後安裝管理器與遊戲時，儘量指向這個目錄底下。

---

## 步驟 1：安裝美版 MapleStory Launcher

1. 到北美楓之谷官方網站下載並安裝 macOS 版 **MapleStory Launcher**：  
   <https://www.nexon.com/maplestory/>  
   安裝說明也可參考 Nexon 支援文件（含 macOS）：  
   <https://support-maplestory.nexon.com/hc/en-us/articles/43855651499284-How-to-install-MapleStory>
2. 開啟 `/Applications/MapleStory Launcher.app`，完成首次啟動。  
   系統會建立 Wine bottle（約在 `~/Library/Application Support/MapleStoryNA/Bottles/maplestory`）。
3. **不必**下載或遊玩美版楓之谷本體；我們只要它的 Wine 環境。

確認 Wine 工具存在：

```sh
ls "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna/MapleStory Launcher/wine"
```

若找不到上述路徑，代表 Launcher 尚未正確安裝。

---

## 步驟 2：用 Wine 安裝橘子遊戲管理器

### 2.1 下載安裝檔

1. 開啟：<https://tw.beanfun.com/ggm/index.html>
2. 下載 **gamania Games Manager**（約十數 MB 的 Windows 安裝程式）。
3. 把下載到的 `.exe` 放到好找的位置，例如 `~/Downloads/`。

下列指令假設安裝檔名為 `~/Downloads/GamesManagerSetup.exe`；請依實際檔名修改。

### 2.2 設定環境並執行安裝

在終端機執行：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory \
  --workdir "$HOME/Downloads" \
  "$HOME/Downloads/GamesManagerSetup.exe"
```

安裝精靈注意：

- 安裝路徑請改成例如：`C:\users\crossover\Documents\ogs\ggm`  
  （對應 macOS：`~/Documents/ogs/ggm`）
- 過程中若提示安裝 **.NET Desktop Runtime / .NET Framework 6**，請接受並完成安裝。
- 安裝完成後，管理器主程式通常是 `GGMWebStart.exe`。

之後若要再開管理器：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory \
  --workdir "$HOME/Documents/ogs/ggm" \
  "$HOME/Documents/ogs/ggm/GGMWebStart.exe"
```

若你的實際路徑不同，把上面的 `ggm` 路徑改成你安裝時選的位置。

---

## 步驟 3：用管理器下載台版楓之谷

1. 在遊戲管理器中登入 Beanfun／選擇楓之谷。
2. 下載並安裝時，**同樣把遊戲目錄設到文件底下**，例如：  
   `C:\users\crossover\Documents\ogs\gamania Games\MapleStory`
3. 等到下載／更新完成，確認存在：

```sh
ls "$HOME/Documents/ogs/gamania Games/MapleStory/MapleStory.exe"
```

路徑可依你實際安裝位置調整。重點是你要能在 Finder 或終端機輕易找到 `MapleStory.exe`。

---

## 步驟 4：用 CitrusGate 啟動遊戲（建議）

台版不能只雙擊 `MapleStory.exe`；必須附上 Beanfun 的帳號 ID 與 OTP。

1. 開啟 [CitrusGate Releases](https://github.com/dspp779/CitrusGate/releases)，下載最新 macOS 可執行檔／App。
2. 若系統提示「無法驗證開發者」，到「系統設定 → 隱私權與安全性」允許開啟，或對 App 按右鍵 → 打開。
3. 依 CitrusGate 介面：
   - 登入 Beanfun；
   - 選擇要進入的遊戲帳號（使用 **ServiceAccountID / T9...**，不是顯示名稱）；
   - 指定台版 `MapleStory.exe` 路徑（例如上面的 Documents 路徑）；
   - 取得 OTP 並啟動。

CitrusGate 會幫你組出完整啟動參數並呼叫遊戲。若工具尚無 Release 或介面有變，請改用下方手動指令。

---

## 步驟 5：手動啟動（備援）

遊戲命令列格式固定為：

```text
MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

在終端機（請替換帳號 ID、OTP，以及遊戲路徑）：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

GAME_DIR="$HOME/Documents/ogs/gamania Games/MapleStory"
ACCOUNT_ID='T9你的帳號ID'
OTP='一次性OTP'

wine --bottle maplestory \
  --workdir "$GAME_DIR" \
  "$GAME_DIR/MapleStory.exe" \
  tw.login.maplestory.beanfun.com 8484 BeanFun "$ACCOUNT_ID" "$OTP"
```

重點：

- `--workdir` 必須是 `MapleStory.exe` 所在目錄。
- `ACCOUNT_ID` 必須與該次 OTP 綁定的帳號一致。
- OTP 用過即失效；失敗時重新向 Beanfun／CitrusGate 取得一組再試。

---

## 常見問題

| 現象 | 可能原因 | 怎麼辦 |
| --- | --- | --- |
| 找不到遊戲或管理器 | 裝進 bottle 的 Program Files | 重裝並改裝到 `Documents`；或用 Finder 搜尋 `MapleStory.exe`／`GGMWebStart.exe` |
| 錯誤 5 | 沒帶有效 OTP | 用 CitrusGate 或手動指令帶上新 OTP |
| 「未登錄的帳號」 | 傳了顯示名稱／錯的 ID，或 ID 與 OTP 不符 | 改用該帳號的 `T9...` ServiceAccountID |
| Traditional Chinese／code-page 錯誤 | locale 不是繁中 | 確認 `LANG`／`LC_ALL`／`LC_CTYPE` 皆為 `zh_TW.UTF-8` 後再啟動 |
| `wine: command not found` | 未設定 `PATH`／未裝 Launcher | 重新執行步驟 2 的 `export`，或確認 Launcher 已安裝 |
| Apple Silicon 打不開 x86 程式 | 未裝 Rosetta | 依系統提示安裝 Rosetta 2 |
| 管理器裝完無法執行 | 缺少 .NET 6 | 回到安裝流程接受 .NET 元件，或再執行一次安裝程式補裝 |

---

## 路徑速查

以下為本教學建議／已驗證的常見位置（使用者名稱請自行對應）：

```text
MapleStory Launcher.app
  /Applications/MapleStory Launcher.app

OEM Wine（cxstart / wine）
  .../Contents/SharedSupport/maplestoryna/MapleStory Launcher/

Bottle
  ~/Library/Application Support/MapleStoryNA/Bottles/maplestory

建議：遊戲管理器
  ~/Documents/ogs/ggm/GGMWebStart.exe

建議：台版楓之谷
  ~/Documents/ogs/gamania Games/MapleStory/MapleStory.exe
```

---

## 免責

- 本流程使用第三方 Wine 環境執行 Windows 版客戶端，可能違反遊戲服務條款，也有帳號風險。
- Nexon、遊戲橘子、Beanfun 皆未為此 macOS 玩法提供官方支援。
- OTP、Cookie、帳號 ID 屬敏感資料，請勿貼到公開頻道或提交到任何版本庫。
