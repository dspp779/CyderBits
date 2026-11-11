#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-graphics-menu.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile only the real popup setup and capability/menu members, so this test
# never constructs a settings window, touches preferences, or starts Wine.
python3 - "$ROOT" "$TEST_DIR" <<'PY'
import pathlib,sys
root,tmp=map(pathlib.Path,sys.argv[1:])
source_root=pathlib.Path(__import__('os').environ.get('CYDER_GRAPHICS_MENU_SOURCE_ROOT',root/'scripts'))
def member(source, signature):
    start=source.index(signature); opening=source.index('{',start); depth=1; end=opening+1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end].replace('private ', '', 1)
classes=[]
for name,file,end,selected in [
    ('GlobalGraphics','cyder_settings_ui.swift','        moltenvkVariant.removeAllItems()', 'graphicsBackendValue'),
    ('GameGraphics','cyder_game_library_ui.swift','        for popup in [fontMingLiu, fontSongti]', 'graphicsBackendOverride'),
]:
    source=(source_root/file).read_text()
    start=source.index('        graphicsBackend.addItems(withTitles: graphicsBackendTitles)')
    setup=source[start:source.index(end,start)]
    signatures=[
        'private var supportsD3DMetalOS:', 'private var canSelectD3DMetal:',
        'private var supportsDxmtOS:', 'private var canSelectDxmt:',
        'private var canSelectDxvk:', 'private var graphicsBackendTitles:',
        'private func updateD3DMetalMenuItemAvailability()',
        'private func updateDxmtMenuItemAvailability()',
        'private func updateDxvkMenuItemAvailability()',
        'private var '+selected+':',
    ]
    members='\n'.join(member(source,s) for s in signatures)
    classes.append('''final class %s: NSObject {
        let graphicsBackend = NSPopUpButton(frame: .zero, pullsDown: false)
        var presentation = TestCapabilities()
        @objc private func graphicsBackendChanged() {}
        override init() { super.init()
%s
        }
%s
    }
''' % (name,setup,members))
fixture=(root/'tests/fixtures/cyder_graphics_menu_availability_harness.swift').read_text()
(tmp/'main.swift').write_text('import AppKit\nimport Foundation\n'+ '\n'.join(classes)+'\n'+fixture)
PY
swiftc -module-cache-path "$TEST_DIR/cache" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
