# DXVK 編譯備忘（1.x / 2.x）

> 對象：在本機重建 Cyder 圖形 payload 的開發者。  
> Wine engine／wineserver／host Mach-O minOS 仍屬 sibling `cyder-wine-engine`；
> DXVK 是 **Windows PE**，由本 repo 的腳本交叉編譯後放進 engine 的 `lib/`。

正式發布路徑仍是：engine 打包**排除** `lib/dxvk`／`lib/dxmt`，再由
`pack-graphics-payloads.sh` 做成 `Resources/graphics/*.tar.zst`。本文件只談
**如何正確編譯**，不涵蓋 CompatDB 選後端或 ensure-graphics 流程
（見 [圖形後端](cyder-graphics-backends.zh-TW.md)）。

## 目錄約定

| 系列 | 腳本 | 安裝目錄 | 目前釘住版本 | 來源 |
|------|------|----------|--------------|------|
| 1.x | `scripts/build-dxvk.sh` | `ENGINE/lib/dxvk/` | CrossOver FOSS snapshot，`RELEASE` = **v1.10.3** | `tools/archives/crossover-sources-25.0.1.tar.gz` 內的 `sources/dxvk` |
| 2.x | `scripts/build-dxvk2.sh` | `ENGINE/lib/dxvk2/` | 上游 **v2.7.1** | `git clone --recurse-submodules`；GitHub src tarball **不夠** |

兩棵樹必須分開。`build-dxvk2.sh` 不得寫入 `lib/dxvk`；重編 1.x 也不得覆蓋 `lib/dxvk2`。

`--engine` 必須是**絕對路徑**。本機 engine 常在 sibling 的
`install/wine-cx26-x86_64`（ogom 的 `install/` 可能是 symlink）。

```bash
# 1.10.3 → lib/dxvk
bash scripts/build-dxvk.sh \
  --engine "$PWD/install/wine-cx26-x86_64"

# 2.7.1 → lib/dxvk2（不碰 lib/dxvk）
bash scripts/build-dxvk2.sh \
  --engine "$PWD/install/wine-cx26-x86_64"
```

## 工具鏈

| 元件 | 位置／備註 |
|------|------------|
| llvm-mingw | `tools/llvm-mingw-20260616-ucrt-macos-universal`（clang 22 + MinGW-w64 15） |
| meson / ninja | 專案內 `.brew-x86/bin`，不要用系統 Homebrew |
| glslang | 1.x 找 `glslangValidator`；2.x 可用 `glslang` 或 `glslangValidator`。2.7.1 的 GLSL 目標是 **vulkan1.3**，舊版 validator 會失敗 |
| 平行度 | `JOBS`（預設 `hw.ncpu`） |

PE 沒有 Mach-O `minOS`。不要對 DXVK DLL 跑 `vtool`／`otool -l` 查 deployment target；
10.15 約束只適用 engine 裡的 host dylib（含 MoltenVK）。

## 版本字串必須釘在 RELEASE

CrossOver 的 dxvk 目錄通常**沒有**自己的 `.git`。Meson 的 `vcs_tag` 會往上走到
Cyder app repo，把 `git describe` 編成例如 `v0.7.0-25-g…`，log 裡就永遠不是
`DXVK v1.10.3`。

`scripts/pin-dxvk-version.py` 會：

1. 讀 `sources/dxvk/RELEASE`（`v1.10.3`／`v2.7.1`）。
2. 把 `vcs_tag(...)` 換成 `configure_file`，寫出 build 目錄的 `version.h`。
3. 在 `src/dxvk/meson.build` 加上 `dxvk_version_inc`，讓 `#include <version.h>`
   找得到**產生出來的**檔案。

**不要**把 `version.h` 寫進 `include/`。那個目錄會蓋掉 Windows SDK 的
`version.h`，接著在 MinGW-w64 15 觸發 `_D3DDEVINFO_RESOURCEMANAGER` 重定義。

安裝後應有純文字 `ENGINE/lib/dxvk/version` 或 `…/dxvk2/version`，內容像
`dxvk v1.10.3`。`pack-graphics-payloads.sh` 靠這個檔案命名 archive，缺了會變成
`unknown`。

用 `strings` 驗 PE 時，clang `-O3` 可能把字面量拆開；同時搜 `DXVK v1.10.3` 與
單獨的 `v1.10.3`。HUD／log 用的是 `DXVK_VERSION` 巨集。

## Wine builtin 戳記

CompatDB 對 DXVK 走 **builtin + prepend**。Wine 的 `mapping.c` 只把 offset 64
寫著 `"Wine builtin DLL"` 的 PE 當 builtin；沒戳的 stock DXVK 會被當成非 builtin，
prepend 無效，遊戲仍載入 WineD3D。

`stamp-wine-builtin-pe.py` 寫入 offset 64、32 bytes（16 字元 + 16 個 NUL）。
`build-dxvk.sh`／`build-dxvk2.sh` 安裝時會跑；`pack-graphics-payloads.sh` 打包前
會再戳一次 `lib/dxvk` 與 `lib/dxvk2`。

```bash
python3 - <<'PY'
from pathlib import Path
p = Path("install/wine-cx26-x86_64/lib/dxvk/x86_64-windows/d3d11.dll")
print(p.read_bytes()[64:80])  # b'Wine builtin DLL'
PY
```

## 1.x（`lib/dxvk`）

來源是 CrossOver 25 FOSS tarball 裡的 snapshot，不是 GitHub `doitsujin/dxvk`
的 1.10.3 tag。預設 work dir：`build/maplestory-oem25/`。

目前安裝模組（win64 + win32）：

`d3d9` `d3d10` `d3d10_1` `d3d10core` `d3d11` `dxgi`

腳本會在原始碼上打兩處相容補丁（可重入）：

| 補丁 | 原因 |
|------|------|
| `src/d3d9/d3d9_include.h`：僅在 `__MINGW64_VERSION_MAJOR < 15` 宣告 `_D3DDEVINFO_RESOURCEMANAGER` | MinGW-w64 15 已有正式定義 |
| `src/d3d10/d3d10_interfaces.h`：略過 MinGW 的 `__CRT_UUID_DECL(ID3D10StateBlock, …)` | 與新 headers 衝突 |

舊文件曾寫「只編 D3D11/DXGI、關掉 D3D9/D3D10」。那是當時避開 header 衝突的
權宜；有了上面兩處補丁後，1.10.3 已編完整 D3D9/D3D10/D3D11 集合。

`set -u` 底下若沒有 `--also-engine`，必須先判斷 `ALSO_ENGINES` 長度再展開陣列
（macOS Bash 3.2 對空陣列 `${arr[@]}` 會 unbound）。

## 2.x（`lib/dxvk2`）

上游 `doitsujin/dxvk` **v2.7.1**。預設 work dir：`build/dxvk-2.7.1/`。

目前安裝模組（win64 + win32）：

`d3d8` `d3d9` `d3d10core` `d3d11` `dxgi`

2.x **沒有**獨立的 `d3d10.dll`／`d3d10_1.dll`（D3D10 走 `d3d10core`）。

### 必須帶 submodule 的原始碼

GitHub 的 `v2.7.1` source tarball（`dxvk-2.7.1-src.tar.gz`）**不含** submodule
內容：`include/vulkan`、`include/spirv`、`subprojects/libdisplay-info` 會是空的。
官方 `dxvk-2.7.1.tar.gz` 則是**預編 PE**，不是給本腳本 meson 的來源。

腳本在來源尚未就緒時會：

```bash
git clone --depth 1 --branch v2.7.1 --recurse-submodules \
  https://github.com/doitsujin/dxvk.git "$SOURCE"
```

已 clone 但缺 header 時：`git submodule update --init --recursive`。
判定齊全：`include/vulkan/include/vulkan/vulkan.h` 存在。

### Clang 22 / libc++

llvm-mingw 2026-06（clang 22）編譯 2.7.1 會在
`src/dxvk/dxvk_pipemanager.cpp` 的

`emplace(std::piecewise_construct, std::tuple(), …)`

失敗（`tuple_element<0, tuple<>>`：parameter pack out of bounds）。這是
libc++ 對空 tuple 的 SFINAE 在 Clang 22 變成硬錯誤，不是 DXVK 邏輯 bug。

上游 [doitsujin/dxvk#5559](https://github.com/doitsujin/dxvk/pull/5559) 的修法是
改成 `std::tuple(key)`。`build-dxvk2.sh` 的 `patch_dxvk2_source` 會套同一行；
已套過則略過。不要為了編譯去改 llvm-mingw 或降 C++ standard。

## 編譯後檢查清單

```bash
eng=install/wine-cx26-x86_64   # 改成實際絕對路徑

# 兩棵樹都在，版本檔分開
cat "$eng/lib/dxvk/version"    # dxvk v1.10.3
cat "$eng/lib/dxvk2/version"   # dxvk v2.7.1

# 戳記
python3 -c "from pathlib import Path; p=Path('$eng/lib/dxvk2/x86_64-windows/d3d11.dll'); print(p.read_bytes()[64:80])"

# 字串（允許被最佳化拆開）
strings -a "$eng/lib/dxvk/x86_64-windows/d3d11.dll" | grep -E 'DXVK v1\.10\.3|v1\.10\.3'
strings -a "$eng/lib/dxvk2/x86_64-windows/d3d11.dll" | grep -E 'DXVK v2\.7\.1|v2\.7\.1'
```

契約測試（不編譯，只檢查腳本約定）：

```bash
bash tests/test-cyder-dxvk.sh
bash tests/test-cyder-dxvk2.sh
bash tests/test-pin-lib-vcs-version.sh
```

## 執行期 payload 路徑

編譯產物經 graphics 管線進入 Cyder 執行期：

- `pack-graphics-payloads.sh` 從 `lib/dxvk`、`lib/dxvk2`、`lib/dxmt` 各打一份
  `Resources/graphics/*.tar.zst`（含 version 與 SHA-256 sidecar）。
- `cyder-ensure-graphics.sh` 解壓至 `~/.cyder/runtime/graphics/`，維護
  `current-dxvk`／`current-dxvk2`／`current-dxmt`，並更新 engine `lib/` symlink。
- CompatDB 與偏好設定的 **`dxvk`** 指向 `lib/dxvk`（1.x）；**`dxvk2`** 指向
  `lib/dxvk2`（2.x）。兩者獨立，重編 2.7.1 只影響選 **DXVK 2** 的程序。

使用者流程見 [圖形後端](cyder-graphics-backends.zh-TW.md)。

## 相關腳本

| 腳本 | 角色 |
|------|------|
| `scripts/build-dxvk.sh` | 1.x → `lib/dxvk` |
| `scripts/build-dxvk2.sh` | 2.x → `lib/dxvk2` |
| `scripts/pin-dxvk-version.py` | 以 `RELEASE` 取代 `git describe` |
| `scripts/stamp-wine-builtin-pe.py` | PE offset 64 builtin 戳記 |
| `scripts/pack-graphics-payloads.sh` | 從 `lib/dxvk`／`lib/dxvk2`／`lib/dxmt` 打 zstd |
