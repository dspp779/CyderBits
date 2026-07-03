#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

DRY_RUN=0
WITH_GUI=0

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --with-gui) WITH_GUI=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

export PATH="$WINE_INSTALL/bin:$PATH"

echo "G1: wine --version"
run arch -x86_64 "$WINE_INSTALL/bin/wine" --version

if [[ "$WITH_GUI" -eq 1 ]]; then
  echo "G2: wine winecfg"
  run arch -x86_64 "$WINE_INSTALL/bin/wine" winecfg
fi

echo "G3 dry-run: launcher command"
run "$SCRIPT_DIR/run-bluecg.sh" --ddraw-source official --dry-run

cat <<'PLAYBOOK'
Manual checks:
1. Run: bash scripts/run-bluecg.sh
2. Confirm BlueLauncher.exe UI appears (G3).
3. Start HD1 mode and confirm bluecg.exe becomes visible (G4).
4. Enter the game world; verify MingLiU text and DirectDraw rendering.

Failure playbook (process killed / no output):
1. Re-run: bash scripts/sign-wine.sh
2. Clear quarantine: xattr -cr install/wine-x86_64
3. Inspect AMFI:
   log show --predicate 'eventMessage CONTAINS "AMFI"' --last 2m
4. If Gatekeeper blocks an x86 binary, allow it in System Settings (user action).
5. Collect debug log for game crashes (not kill-on-launch):
   WINEDEBUG=+module,+virtual,+seh arch -x86_64 install/wine-x86_64/bin/wine bluecg.exe \
     updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:0 \
     2>&1 | tee logs/bluecg-debug.log

Optional source workarounds (docs only; only after clean build fails):
1. Match error to W1/W2/W3 in the plan; try preferred fix first.
2. Manually apply any needed subset (one, two, or all three) with the sed commands in the plan.
3. Record applied IDs in logs/workarounds.md, then rebuild + resign.
4. When done or ineffective, restore changed files from crossover-sources-26.2.0.tar.gz and rebuild + resign.
PLAYBOOK
