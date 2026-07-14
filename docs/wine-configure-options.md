# Wine `configure` 選項參考（macOS 引擎建置）

> 對象：重新建置 Cyder / CyderBits Wine 引擎的開發者。  
> 情境：**macOS + CrossOver Wine（`winemac.drv`）+ 經典 Windows 遊戲**（Win95～XP 世代、32-bit PE、DirectDraw / GDI 為主）。  
> 實際建置腳本：`scripts/build-wine.sh`（執行 configure 前會印出完整指令）。

## ogom 建置與目前發布 engine

原始碼重新建置若未指定選項，`scripts/build-wine.sh` 仍以 `--without-vulkan` 作為 BlueCG 的最小建置路徑；但目前封裝給 Cyder 的 `CX26.2.0-W11-Cyder003` 已使用 Vulkan build，並在 artifact 內含 x86_64 `libMoltenVK.dylib`。兩者是不同層級：configure 預設不等於目前發布 artifact 的內容。

`scripts/build-wine.sh` 傳給 Wine `configure` 的旗標：

| 旗標 | 說明 |
|------|------|
| `-C` | 使用 config.cache，加速重複 configure |
| `--enable-win64` | 64-bit Wine + WoW64，在 64-bit prefix 跑 32-bit PE |
| `--enable-archs=i386,x86_64` | 同時建 32/64-bit PE（`syswow64` 等） |
| `--with-mingw=llvm-mingw` | 使用專案內 llvm-mingw 交叉編譯 PE DLL |
| `--prefix=...` | 安裝至 `install/wine-cx25-x86_64` 或 `wine-cx26-x86_64` |
| `--without-vulkan` | clean source build 的預設；DirectDraw 老遊戲不需 Vulkan |
| `--with-vulkan` | 可選；搭配 `--vulkan-source homebrew\|crossover`，見 `scripts/build-graphics-stack.sh` |

建置前後相關腳本：

```text
prepare-build-deps.sh   → 解壓 CrossOver 原始碼
build-graphics-stack.sh → CrossOver MoltenVK（--vulkan-source crossover 時）
build-wine.sh           → configure + make + install
bundle-wine-dylibs.sh   → 打包 runtime dylib（含 libMoltenVK，若啟用 Vulkan）
```

### 老遊戲必備三件套

以下缺一不可（BlueCG 等 PE32 遊戲）：

1. `--enable-win64`
2. `--enable-archs=i386,x86_64`（僅 `x86_64` 會導致 `syswow64\ntdll.dll` 載入失敗）
3. `--with-mingw=...`（ogom 使用 llvm-mingw）

---

## 重要性速查

| 標記 | 含義 |
|------|------|
| **必要** | 老遊戲引擎建置應保留／必須設定 |
| **建議保留** | 預設讓 configure 自動偵測，不要主動 `--without-*` |
| **可關** | 可為縮短建置或瘦身而關閉 |
| **無關** | macOS 顯示／音效路徑用不到（多為 Linux） |
| **進階** | 特殊交叉建置或除錯才需要 |

---

## X11 相關

macOS 上使用 **`winemac.drv`（Cocoa）**，不走 X11。下列選項在 Mac 引擎建置中**通常無關**。

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--with-x` | 啟用 X Window System 顯示驅動 | **無關**（Mac） |
| `--x-includes=DIR` | X11 標頭路徑 | **無關** |
| `--x-libraries=DIR` | X11 函式庫路徑 | **無關** |
| `--without-wayland` | 不建 Wayland driver | **無關**（Linux） |
| `--without-xcomposite` | 不用 X Composite | **無關** |
| `--without-xcursor` | 不用 Xcursor | **無關** |
| `--without-xfixes` | 不用 Xfixes（剪貼簿變更通知等） | **無關** |
| `--without-xinerama` | 不用 Xinerama（舊多螢幕） | **無關** |
| `--without-xinput` | 不用 X Input extension | **無關** |
| `--without-xinput2` | 不用 X Input 2 | **無關** |
| `--without-xrandr` | 不用 Xrandr（多螢幕） | **無關** |
| `--without-xrender` | 不用 Xrender | **無關** |
| `--without-xshape` | 不用 Xshape | **無關** |
| `--without-xshm` | 不用 XShm 共享記憶體 | **無關** |
| `--without-xxf86vm` | 不用 XFree86 視訊模式 | **無關** |

> Mac 上多螢幕、視窗縮放等行為由 `winemac.drv` 處理，與 X11 extension 無關。

---

## Optional Features（架構與建置行為）

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--enable-archs={i386,x86_64,...}` | 指定要編譯的 PE 架構 | **必要**：至少 `i386,x86_64` |
| `--enable-win64` | 建 64-bit Wine（含 WoW64） | **必要** |
| `--disable-win16` | 關閉 Windows 3.x **16-bit** 支援 | **可關**（目標為 Win32 PE 時）；要跑真正 Win16 程式則不能關 |
| `--disable-tests` | 不編譯 Wine 回歸測試 | **可關**（僅縮短建置，不影響執行） |
| `--disable-option-checking` | 忽略無法辨識的 `--enable/--with` | 進階；打錯旗標不會報錯 |
| `--enable-build-id` | 在 object 加入 `.buildid` | 開發／CI 用，與遊戲無關 |
| `--enable-maintainer-mode` | 維護者建置規則（觸發額外 regen） | **不要開**（ tarball 建置） |
| `--enable-sast` | Clang 靜態安全分析 | CI 用 |
| `--enable-silent-rules` | 安靜版 `make` | 純輸出格式 |
| `--enable-werror` | 警告視為錯誤 | 自建引擎不建議隨便開 |
| `--disable-largefile` | 不支援大檔案 | 極少需要 |
| `--disable-year2038` | 不支援 2038 年後時間戳 | 極少數老程式可能相關；一般不管 |

---

## 圖形 API

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--without-opengl` | 關閉 OpenGL | **不要關**。macOS 上 wined3d、許多 DirectDraw / GDI 路徑依賴 OpenGL |
| `--without-vulkan` | 關閉 Vulkan（winevulkan、D3D10+ 現代路徑） | **DirectDraw / 2D 可關**；D3D9+ 需開並搭配 MoltenVK |
| `--without-osmesa` | 關閉離屏 OpenGL（OSMesa） | 一般老遊戲可不管 |
| `--without-opencl` | 關閉 OpenCL | **不需要**（2D 老遊戲） |

### Vulkan 與 ogom 路徑

| 目標 | configure | 額外步驟 |
|------|-----------|----------|
| BlueCG / DirectDraw | `--without-vulkan` 可用；目前 A6 packaged engine 另含 MoltenVK | BlueCG 仍走 ddraw → wined3d/OpenGL；若 configure 缺 `SONAME_LIBVULKAN` 見 `patches/w1-win32u-vulkan-soname.patch` |
| 實驗性 3D / DXVK 路線 | `--with-vulkan` | `build-wine.sh --vulkan-source homebrew` 或 `crossover` + `build-graphics-stack.sh` |

---

## 音效

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--without-coreaudio` | 關閉 macOS CoreAudio | **不要關**（Mac 主要音效後端） |
| `--without-alsa` | 關閉 ALSA | **無關**（Linux） |
| `--without-pulse` | 關閉 PulseAudio | **無關**（Linux） |
| `--without-oss` | 關閉 OSS | **無關** |
| `--without-ffmpeg` | 關閉 FFmpeg | 有影片／過場的遊戲 **建議保留** |
| `--without-gstreamer` | 關閉 GStreamer 多媒體 | 有 FMV 的遊戲 **建議保留** |

---

## 字型與文字

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--without-freetype` | 關閉 FreeType | **不要關**（GDI 字型、UI 文字） |
| `--without-fontconfig` | 關閉 fontconfig | Linux 字型配置；Mac 上多由系統路徑處理，**預設即可** |
| `--without-gettext` | 關閉 gettext | Wine 訊息 i18n，**不影響遊戲執行** |
| `--with-gettextpo` | 用 GetTextPO 重建 po | 翻譯維護用 |

---

## 網路、安全、周邊

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--without-gnutls` | 關閉 GnuTLS（TLS / schannel 等） | 單機遊戲通常可不管；連線版可能有幫助 |
| `--without-gssapi` | 關閉 GSSAPI（Kerberos SSP） | **不需要** |
| `--without-krb5` | 關閉 Kerberos | **不需要** |
| `--without-netapi` | 關閉 Samba NetAPI | 區網老遊戲偶爾有用 |
| `--without-cups` | 關閉列印（CUPS） | **不需要** |
| `--without-capi` | 關閉 CAPI（ISDN） | **不需要** |
| `--without-dbus` | 關閉 D-Bus 裝置熱插拔 | **無關**（Linux） |
| `--without-udev` | 關閉 udev | **無關**（Linux） |
| `--without-usb` | 關閉 libusb | 極少數硬體鎖；**預設保留** |
| `--without-pcsclite` | 關閉 PC/SC 智慧卡 | **不需要** |
| `--without-pcap` | 關閉封包擷取 | **不需要** |
| `--without-gphoto` | 關閉數位相機 | **不需要** |
| `--without-sane` | 關閉掃描器 | **不需要** |
| `--without-v4l2` | 關閉視訊擷取 | **無關**（Linux） |

---

## 執行期基礎與檔案監視

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--without-mingw` | 不用 MinGW 交叉編譯器 | **不可關**（ogom 必須 `--with-mingw`） |
| `--without-pthread` | 關閉 pthread | **不要關** |
| `--without-unwind` | 關閉 libunwind（例外展開） | **不要關** |
| `--without-inotify` | 關閉 inotify 檔案監視 | 部分啟動器會監看檔案；CrossOver on Mac 可能用 **libinotify** dylib，**建議保留** |
| `--without-sdl` | 關閉 SDL 整合 | 少數遊戲依賴 SDL；**預設保留較安全** |

---

## 進階路徑與交叉建置

| 選項 | 用途 | 老遊戲 |
|------|------|--------|
| `--with-system-dllpath=PATH` | 從 PATH 載入外部 PE 依賴 DLL | 除錯、手動替換 DLL 時 |
| `--with-wine-tools=DIR` | 使用指定目錄的 wine 工具 | 分離式交叉建置 |
| `--with-wine64=DIR` | Wow64 分離建置（64-bit 指向另一套 wine64） | ogom 使用 unified `build64`，**通常不用** |

---

## 依遊戲類型調整建議

| 遊戲類型 | 應特別注意的 configure 面向 |
|----------|------------------------------|
| Win95～XP、DirectDraw / GDI、PE32 | `win64` + `archs=i386,x86_64` + mingw；保留 OpenGL、CoreAudio、FreeType |
| 含影片過場（FMV） | 保留 gstreamer、ffmpeg |
| 純 2D、DirectDraw（如 BlueCG） | 可 `--without-vulkan`；不必建 VKD3D / DXVK |
| D3D9～D3D12、較新 3D | 需 Vulkan（`--with-vulkan`）+ MoltenVK；日後 VKD3D phase 2 |
| 真正的 Win16（Windows 3.x） | 不可 `--disable-win16` |

---

## 建置決策清單（重新建引擎前）

1. **CX 版本**：`--cx 25` 或 `26`（對應 `crossover-sources-*.tar.gz`）。
2. **目標遊戲架構**：是否為 PE32 → 確認 `--enable-archs=i386,x86_64`。
3. **圖形世代**：2D DirectDraw vs 3D Vulkan → `--without-vulkan` 或 `--with-vulkan`。
4. **Vulkan 來源**（若啟用）：`homebrew`（快速）或 `crossover`（與 CX tarball 版本鎖定）。
5. **瘦身**：考慮 `--disable-tests`、`--disable-win16`；勿關 OpenGL / CoreAudio / FreeType。
6. **configure 後**：檢查 `build-wine.sh` 印出的 `configure command:` 是否與預期一致。
7. **打包前**：`bundle-wine-dylibs.sh`、`sign-wine.sh`、`strip-wine-install.sh`（見 `docs/scripts.md`）。

---

## 相關文件

- [scripts.md](scripts.md) — `build-wine.sh`、`build-graphics-stack.sh` 腳本說明
- [bluecg.md](bluecg.md) — BlueCG 驗證與已知問題
- [../patches/README.md](../patches/README.md) — W1 Vulkan 編譯 fallback 等選用 patch
- [superpowers/specs/2026-07-03-bluecg-wine-build-design.md](superpowers/specs/2026-07-03-bluecg-wine-build-design.md) — 自建 Wine 總設計
