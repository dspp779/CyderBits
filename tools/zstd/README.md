# Cyder zstd tool

`zstd` is a universal (`x86_64 arm64`) macOS CLI built from upstream zstd 1.5.7.
It is committed so Cyder users do not need Homebrew merely to install an engine.

- upstream source: `https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz`
- source SHA-256: `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3`
- build: `bash scripts/build-universal-zstd.sh`
- runtime dependencies: Apple `libSystem` only
- deployment: Intel macOS 10.12+, Apple silicon macOS 11.0+

The adjacent `LICENSE` is copied unchanged from the source archive.
