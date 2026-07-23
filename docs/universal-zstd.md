# 內建 Universal zstd

Cyder 內建以官方 zstd 1.5.7 source 建置的 universal CLI，讓 `.tar.zst` engine archive 在
使用者沒有 Homebrew、MacPorts 或系統 `zstd` 時仍可解壓。

```text
tools/zstd/zstd
  x86_64: macOS 10.12+
  arm64:  macOS 11.0+（Apple silicon 最早可用版本）
```

二進位只連結 `/usr/lib/libSystem.B.dylib`；build 明確停用 zlib、lzma、lz4 與 legacy codec，
沒有 `/opt/homebrew`、`/usr/local` 或其他動態相依。`Cyder.app` 將它放在
`Contents/Resources/tools/zstd/zstd`，解壓時優先使用 app 內版本，再退回 PATH。

重建方式：

```sh
bash scripts/build-universal-zstd.sh
bash tests/test-universal-zstd.sh
```

Build script 固定 source SHA-256，產出後合併 x86_64/arm64、strip、adhoc sign。測試會檢查
兩個 slices、deployment target、動態依賴、壓縮 round trip，以及在 PATH 沒有外部 zstd
時完成一個 `.tar.zst` engine-layout 解壓。

2026-07-21 另以 `create-cyder-app.sh` 實際建立完整測試 app：bundle 內的 zstd 仍是
`x86_64 arm64`、在只有 `/usr/bin:/bin` 的 PATH 可執行，且整個 app 通過
`codesign --verify --deep --strict`。因此不只是 repo 內 CLI fixture 可用，最終 app payload
也已驗證。

macOS 10.12/10.13 只可能運行 Intel slice；arm64 deployment target 必須是 11.0，因為更早
的 macOS 沒有 Apple silicon。Cyder 主程式及 Wine 本身的最低系統需求仍須分別驗證；
zstd 相容不代表整個 app 自動支援 10.12。
