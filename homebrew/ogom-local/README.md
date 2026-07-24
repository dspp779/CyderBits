# ogom/local (vendored Homebrew tap)

Build-time formulae that must not rely on `.brew-x86` alone.

`Formula/gnutls.rb` is homebrew-core’s gnutls with the “Backport support for
building with older clang” patch removed: that patch downloads a GitLab
`.diff` which currently returns HTTP 403, and modern Xcode Clang does not need
it. `scripts/env-x86_64.sh` (`brew_x86_ensure_local_tap` /
`brew_x86_install_runtime`) syncs this tree into
`.brew-x86/Library/Taps/ogom/homebrew-local` and installs `ogom/local/gnutls`
instead of core `gnutls`.
