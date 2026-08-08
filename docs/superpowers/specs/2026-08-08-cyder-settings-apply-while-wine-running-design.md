# Cyder Preferences: Apply While Wine Is Running

**Status:** implemented  
**Date:** 2026-08-08  
**Goal:** Stop silent / misleading preference saves while a Wine prefix is active, and make registry + `settings.json` stay consistent when the user explicitly applies.

## Problem

With Wine already running, changing preferences (for example Retina / DPI) often appears saved, then reverts after Wine exits. Root causes in the current flow:

1. Control changes write `settings.json` immediately, but **skip** live registry apply when the prefix is busy (`cyder_apply_user_settings` returns early unless `CYDER_FORCE_SETTINGS=1`).
2. Editing `user.reg` on disk while wineserver is alive can be **overwritten** when wineserver flushes its in-memory hive on exit.
3. Advanced **「套用所有設定」** is easy to miss; status text claims deferred apply without a clear apply action in the main chrome.

`reg add` against a live wineserver updates memory; an exit flush then persists the **new** values. Disk-only `user.reg` edits do not.

## Decisions

| Topic | Choice |
|-------|--------|
| Wine running + Apply | Live Wine registry write (`reg add` / existing apply-settings path that talks to Wine), **then** write `settings.json` only on success |
| Wine running + control tweaks | Draft in UI only until Apply |
| Wine idle | Keep today’s immediate save to JSON + fast prefix apply (`edit-user-reg` / equivalent) |
| Advanced 「套用所有設定」 | **Remove** (button + explanatory note) |
| Rebuild / Winetricks | Keep on Advanced tab |

## UX

### On open (Wine running)

Show an alert once when the preferences window is prepared for display:

- Message: game / Wine is running.
- Informative: changes must be applied via **「套用設定」** to save; a **full quit and relaunch** is required for settings such as Retina / DPI to take effect in the session.

### Chrome

- **「套用設定」** button visible while Wine is running (footer / toolbar near status). Hidden or disabled when Wine is idle (immediate-save path covers idle).
- **Status (bottom-left)** while Wine is running (idle draft state):

  > 目前遊戲正在執行中，需套用設定才會儲存設定，並且完全重開才會套用成功。

- After successful Apply while running:

  > 已寫入環境並儲存；請完全退出遊戲後再重開以完整套用。

- On Apply failure: do **not** update `settings.json`; show an error status (and keep drafts).

### Advanced tab

- Remove **「套用所有設定」** and its note about full Wine writes.
- Keep rebuild environment and Winetricks.

## Behavior detail

### Wine running

1. Control changes update UI draft state only (`isDirty`); no `settings.json`, no registry.
2. **套用設定**:
   1. Persist draft → invoke launcher / helper with force registry apply against the **live** prefix (`CYDER_FORCE_SETTINGS=1` or equivalent `reg add` path—not disk-only `cyder-edit-user-reg.sh` while busy).
   2. On success → write `settings.json` from the applied draft.
   3. Refresh status; leave window open unless product flow requires otherwise.
3. Do **not** auto-kill games on Apply (user chose not to stop-all for this flow).

### Wine idle

1. Unchanged: control changes call immediate save (JSON + fast registry path when needed).
2. Status: 「變更會立即儲存」 (or existing success / failure strings).

### Detection

Reuse `hasRunningExes` / `cyder_has_running_prefix` (socket present). Re-check on `prepareForDisplay` and before Apply.

## Non-goals

- Automatically quitting Wine when Apply is pressed.
- Migrating already-running sessions’ in-game coordinate scale without relaunch (Retina still needs full restart).
- Replacing golden / bootstrap DllOverrides work.

## Test plan

- Update `tests/test-cyder-force-settings-ui.sh` (and related UI source assertions): expect **「套用設定」**, not **「套用所有設定」**; assert running-mode draft / apply ordering comments or symbols as practical.
- Cover: idle path still immediate-saves; running path does not call save-to-disk until Apply success; Apply failure leaves store unchanged (unit / harness level where fixtures exist).
- Manual: with Steam/game running, toggle Retina, Apply, quit Wine fully, confirm `user.reg` / next launch match UI.

## Implementation touchpoints (expected)

- `scripts/cyder_settings_ui.swift` — draft mode, Apply button, status, remove advanced apply-all.
- `scripts/cyder_app_main.swift` — wire Apply to force live registry apply then confirm store save; open alert when running.
- `scripts/cyder-common.sh` / apply helpers — ensure forced apply uses Wine client (`reg add` / `cyder-apply-settings.sh`), not disk edit, when prefix is running.
- `tests/test-cyder-force-settings-ui.sh` — assertions for new UX.
