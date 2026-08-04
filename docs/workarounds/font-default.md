# 繁中預設字體 workaround

Cyder 以兩組獨立的字體取代控制繁中 fallback：

1. **細明體取代**（`fontMingLiuTarget`）：`MingLiU`、`PMingLiU`、`MS Shell Dlg` 等細明體組來源
2. **宋體取代**（`fontSongtiTarget`）：`SimSun`、`NSimSun`、`宋体` 等宋體組來源

每組可選：細明體、宋體（Songti TC）、蘋方（PingFang TC）。宋體與蘋方為 macOS 內建；細明體需使用者自行合法安裝。Cyder 只寫 Wine `Fonts\Replacements` 規則，不會散布或安裝商用字體。

### 預設值

- 細明體組：若 macOS 已有 MingLiU 則為 `mingliu`（不強制取代）；否則改指到 `songti`
- 宋體組：`songti`（仍寫入 `SimSun → Songti TC` 以確保可讀性）
- 高解析度顯示（Retina）預設關閉；DPI 預設 96
- 「顯示畫面流暢度」（Metal／DXVK HUD）預設關閉；「全部恢復預設值」亦會重設為關閉

### 宋體組特例

選「宋體」時，即使細明體組選「細明體」，宋體組仍會寫入 `Songti TC` 取代規則（與舊版單一 `songti` preset 行為一致）。

選「細明體」於細明體組表示刪除該組取代 key，讓 Wine 使用系統／prefix 中實際存在的 MingLiU；使用者必須自行合法安裝字體。

實作位置：[`scripts/cyder-apply-settings.sh`](../../scripts/cyder-apply-settings.sh)、[`scripts/cyder-edit-user-reg.sh`](../../scripts/cyder-edit-user-reg.sh)。

這個 workaround 解決的是繁中文字型 fallback 與可讀性，不是 BlueCG 的 GL resize 黑屏。BlueCG 的視窗問題請看 [A6 resize workaround](bluecg-a6-resize.md).
