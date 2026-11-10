# GameToMac 與新楓之谷 pipeline 卡頓研究

2026-09-21 已把 GameToMac 0.1.19 Alpha build 57 安裝到
`/Applications/GameToMac.app`，簽署及公證驗證通過。本機 macOS 15.7.7
低於它要求的 macOS 26.0，啟動被系統拒絕，尚未完成 app GUI／Steam 操作。

本輪從 app 附帶的原始碼，確認 AoE IV generated-code cache、AoE II query
short-circuit 與 CS2／Overwatch DXMT pipeline archive 是不同層次的最佳化。
已在引擎 repo 實作獨立、預設停用的 DXMT v0.80 graphics pipeline archive 實驗，
用 D3D11 真實像素讀回檢查 cache 與 fallback。尚未完成楓之谷遊戲內 first-hit A/B。

- [完整研究、安裝證據與限制](../../../cyder-wine-engine/docs/gametomac-maplestory-pipeline-study.zh-TW.md)
- [實驗 patch、建置及 A/B 步驟](../../../cyder-wine-engine/tools/dxmt-pipeline-lab/README.md)
- [Buffer／紋理、CPU 與提交同步研究](../../../cyder-wine-engine/docs/maplestory-dxmt-resource-cpu-submit-study.zh-TW.md) — 逐列上傳測量、初始化遺失 GPU 重現、回收邊界與同步優化候選。
- [資源測試工具與原始證據](../../../cyder-wine-engine/tools/dxmt-resource-study/README.md)
- [既有世紀帝國研究](age-of-empires-rosetta-wine-stutter-research.zh-TW.md)
- [GameToMac 官網](https://www.gametomac.com)

Wine／renderer 程式修改由 `cyder-wine-engine` 管理；此處只保留應用層索引。
