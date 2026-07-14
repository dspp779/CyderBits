# 繁中預設字體 workaround

Cyder 的繁中預設字體方案是 `songti`，會把 Windows 常見的 `MingLiU`、`PMingLiU`、`SimSun` 等替代到 macOS 的 **Songti TC**。字體平滑預設為灰階；這是 prefix registry 的替代規則，不會散布或安裝任何商用字體。

實作位置：[`scripts/cyder-apply-settings.sh`](../../scripts/cyder-apply-settings.sh)。可選的 `mingliu` 方案會移除 `MingLiU → Songti TC` 規則，讓 Wine 使用系統／prefix 中實際存在的 MingLiU；使用者必須自行合法安裝字體。

這個 workaround 解決的是繁中文字型 fallback 與可讀性，不是 BlueCG 的 GL resize 黑屏。BlueCG 的視窗問題請看 [A6 resize workaround](bluecg-a6-resize.md)。
