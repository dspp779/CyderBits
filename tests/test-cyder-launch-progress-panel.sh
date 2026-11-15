#!/usr/bin/env bash
# The passive launch panel must be visible while Cyder is inactive. A Finder
# double-click leaves Cyder in the background; with orderFront(nil) the panel
# sat behind the frontmost app for the whole 30-40 s launch, so the launch
# looked stalled until the user clicked Cyder.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

support="$(cat "$ROOT/scripts/cyder_launch_support.swift")"
show="$(awk '/final class CyderSetupPanel/{p=1} p && /    func show\(\) \{/{s=1} s{print} s && /^    }$/{exit}' \
  "$ROOT/scripts/cyder_launch_support.swift")"
passive_branch="$(awk '/if passive \{/{p=1;next} p && /\} else \{/{exit} p && !/^ *\/\//{print}' <<<"$show")"

assert_contains "$support" ".nonactivatingPanel" \
  "the passive panel must stay non-activating so it never takes focus from the user"
assert_contains "$passive_branch" "window.orderFrontRegardless()" \
  "the passive panel must order above other apps while Cyder is inactive"
if grep -Fq "orderFront(nil)" <<<"$passive_branch"; then
  echo "ASSERT failed: orderFront(nil) leaves the passive panel behind the frontmost app" >&2
  exit 1
fi
if grep -Eq "activate|makeKey" <<<"$passive_branch"; then
  echo "ASSERT failed: the passive panel must not activate Cyder or become key" >&2
  exit 1
fi

echo "PASS: passive launch panel is shown above other apps without taking focus"
