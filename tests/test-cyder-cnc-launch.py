#!/usr/bin/env python3
"""Offline integration checks of the real per-launch manager and shell dispatcher.
Uses synthetic PE games, the pinned real payload, and a file-only engine fixture.
Never runs Wine, game code, UI, signing, network, or existing user state.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / 'scripts/cyder-cnc-game.rb'
LEGACY = ROOT / 'scripts/cyder-cnc-game-legacy.rb'
checks = []
EXTERNAL_ENGINE = Path(sys.argv[1]) if len(sys.argv)>1 else None

def check(condition, name):
    assert condition, name
    checks.append(name)


def fixture_pe(path, dll=False):
    subprocess.run(['/usr/bin/python3', str(ROOT/'tests/fixtures/make-cnc-pe.py'), str(path)], check=True)
    if dll:
        data = bytearray(path.read_bytes())
        struct.pack_into('<H', data, 150, 0x2102)
        path.write_bytes(data + b'CYDER_NATIVE_DDRAW_PATH_V1')


def tree(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


with tempfile.TemporaryDirectory(prefix='cyder-cnc-launch-') as tmp:
    tmp = Path(tmp).resolve()
    support = tmp/'support'; support.mkdir(mode=0o700)
    prefix = tmp/'prefix'; (prefix/'drive_c').mkdir(parents=True, mode=0o700)
    (prefix/'cxbottle.conf').write_text('[EnvironmentVariables]\n"MARKER" = "preserve"\n')
    bottle_before = (prefix/'cxbottle.conf').read_bytes()
    engine = tmp/'engine'; (engine/'lib/wine/i386-windows').mkdir(parents=True)
    (engine/'bin').mkdir(); (engine/'bin/wine').touch()
    (engine/'engine-manifest.json').write_text(json.dumps({'capabilities':['native-ddraw-path-v1', 'future-capability']}))
    fixture_pe(engine/'lib/wine/i386-windows/ntdll.dll', dll=True)
    games = []
    for name in ['遊戲 A', 'game B', 'unrelated']:
        directory = tmp/name; directory.mkdir()
        exe = directory/'game.exe'; fixture_pe(exe)
        (directory/'save.dat').write_text('original progress\n')
        (directory/'ddraw.ini').write_text('original game config\n')
        games.append(exe)
    a, b, other = games
    before = {str(p.parent):tree(p.parent) for p in games}
    env = os.environ.copy()
    for key in ['CYDER_DDRAW_PATH','CNC_DDRAW_CONFIG_FILE','WINEDLLOVERRIDES','CYDER_WINE_DLL_OVERRIDES',
                'CYDER_BLUECG_BLIT_FILTER','CYDER_GRAPHICS_BACKEND_PATH','CYDER_WINE_FRONTEND_ARGS',
                'CYDER_GRAPHICS_PREFERENCE','CYDER_GRAPHICS_BACKEND','CX_GRAPHICS_BACKEND']:
        env.pop(key, None)
    env.pop('CYDER_TEST_SETTINGS_REQUEST', None)
    env.update(CYDER_SUPPORT=str(support), LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')

    def call(command, exe=a, argument=None, engine_arg=None, accept=True, extra=None, manager=MANAGER):
        argv = ['/usr/bin/ruby', str(manager), command, str(exe)]
        if argument is not None: argv.append(str(argument))
        if engine_arg is not None: argv.append(str(engine_arg))
        result = subprocess.run(argv, env=dict(env, **(extra or {})), capture_output=True, text=True)
        if accept:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert result.returncode != 0, (command, 'unexpected acceptance')
        return result.stderr

    check(call('status')['mode']=='off', 'unconfigured source is off without game mutation')
    check(call('enable', argument='{"filter":"nearest","maxfps":30}')['settings']=={'filter':'nearest','maxfps':30}, 'official per-game settings accepted')
    check(call('enable', b, '{"filter":"bilinear","maxfps":120}')['mode']=='on', 'second game independently enabled')
    aid = 'profile-'+hashlib.sha256(str(a).encode()).hexdigest()[:24]
    check(call('status')['profileID']==aid, 'canonical EXE stable profile ID matches native contract')
    shell_id=subprocess.check_output(['/bin/bash',str(ROOT/'scripts/cyder-profile.sh'),'id',str(a)],text=True).strip()
    check(shell_id==aid, 'actual profile.sh agrees on canonical Unicode-path ID')
    alias=tmp/'alias.exe';alias.symlink_to(other)
    check(call('launch',alias,prefix,engine)['mode']=='off', 'ordinary stock symlink EXE remains launchable')
    call('enable',alias,accept=False)
    if EXTERNAL_ENGINE:
        check(call('status',a,EXTERNAL_ENGINE)['capability']=='available', 'actual isolated rc.3 engine manifest and i386 PE marker accepted read-only')
    check('更新引擎' in call('launch', a, prefix, tmp, accept=False), 'old engine capability denied')
    marker = engine/'lib/wine/i386-windows/ntdll.dll'; old_marker=marker.read_bytes()
    marker.write_bytes(old_marker.replace(b'CYDER_NATIVE_DDRAW_PATH_V1', b'NO_FEATURE_MARKER_PRESENT'))
    check('功能標記' in call('launch', a, prefix, engine, accept=False), 'manifest alone cannot enable old PE')
    marker.write_bytes(old_marker)
    out_a = call('launch', a, prefix, engine); out_b = call('launch', b, prefix, engine)
    check(out_a['dllPath']==out_b['dllPath'] and out_a['dllPath'].startswith('Z:\\'), 'one verified external payload used for two games')
    check(out_a['configPath'] != out_b['configPath'], 'per-game immutable snapshot paths differ')
    def ini_path(value):
        return prefix/'drive_c'/Path(value.removeprefix('C:\\').replace('\\','/'))
    ini_a=ini_path(out_a['configPath']); ini_b=ini_path(out_b['configPath'])
    bytes_a=ini_a.read_bytes(); bytes_b=ini_b.read_bytes()
    check(b'shader=Nearest neighbor' in bytes_a and b'maxfps=30' in bytes_a and b'savesettings=0' in bytes_a, 'A snapshot contains its own official values')
    check(b'shader=Bilinear' in bytes_b and b'maxfps=120' in bytes_b and b'savesettings=0' in bytes_b, 'B snapshot contains different official values')
    check(out_a['configPath'].isascii() and len(out_a['configPath'])<260, 'private INI path stays ANSI MAX_PATH-safe')
    for argument in ['{"filter":"other","maxfps":60}', '{"filter":"nearest","maxfps":0}', '{"filter":"bilinear","maxfps":true}', '{"filter":"bilinear","maxfps":60,"path":"other"}']:
        call('enable', argument=argument, accept=False)
    check(call('status')['settings']=={'filter':'nearest','maxfps':30}, 'invalid options do not replace saved settings')
    saved=json.loads((support/'directdraw'/aid/'settings.json').read_text())
    check(saved['template'].encode()==bytes_a, 'stable per-profile template atomically accompanies official settings')
    unknown=b.parent/'ddraw.dll'; unknown.write_bytes(b'unknown wrapper')
    call('launch',b,prefix,engine,accept=False);unknown.unlink()
    conflict=b.parent/'dxgi.dll';conflict.write_bytes(b'other graphics wrapper')
    call('launch',b,prefix,engine,accept=False);conflict.unlink()
    check(True, 'unknown local DLL and other graphics wrapper remain protected')
    call('enable', argument='{"filter":"bilinear","maxfps":144}')
    new_a=call('launch', a, prefix, engine)
    check(new_a['configPath'] != out_a['configPath'] and ini_a.read_bytes()==bytes_a, 'settings update preserves launcher-child snapshot')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        concurrent_results=list(pool.map(lambda exe:call('launch',exe,prefix,engine), [a,b,a,b]))
    check(all(r['mode']=='on' for r in concurrent_results), 'parallel launches share immutable verified files safely')
    for extra in [{'WINEDLLOVERRIDES':'*ddraw.dll=b'}, {'CYDER_GRAPHICS_BACKEND':'dxvk'}, {'CYDER_DDRAW_PATH':'Z:\\foreign\\ddraw.dll'}, {'CNC_DDRAW_CONFIG_FILE':'C:\\other.ini'}]:
        call('launch',a,prefix,engine,accept=False,extra=extra)
    check(True, 'conflicting graphics and foreign path environment refused')
    aliases = ['cyder_ddraw_path','CyDeR_DdRaW_PaTh','cnc_ddraw_config_file','CnC_DdRaW_CoNfIg_FiLe']
    for key in aliases:
        for value in ['', 'foreign-sentinel']:
            call('launch',a,prefix,engine,accept=False,extra={key:value})
    call('launch',a,prefix,engine,accept=False,extra={'CYDER_DDRAW_PATH':'','cyder_ddraw_path':'foreign-sentinel'})
    check(True, 'standalone manager refuses lower/mixed/duplicate and empty internal aliases')
    check(call('launch',a,prefix,engine,extra={'CYDER_DDRAW_PATH_EXTRA':'unrelated'})['mode']=='on', 'standalone manager preserves unrelated similarly named environment')
    dll=Path(out_a['dllPath'][2:].replace('\\','/')); dll_before=dll.read_bytes(); dll.chmod(0o600); dll.write_bytes(b'bad')
    check('已被變更' in call('launch',a,prefix,engine,accept=False), 'staged payload tampering refused')
    dll.write_bytes(dll_before); dll.chmod(0o444)
    # An immutable snapshot that has been replaced by a symlink is never followed.
    victim=ini_path(new_a['configPath']); keep=victim.read_bytes(); victim.unlink();victim.symlink_to(tmp/'outside')
    call('launch',a,prefix,engine,accept=False);victim.unlink();victim.write_bytes(keep);victim.chmod(0o444)
    check(not (tmp/'outside').exists(), 'snapshot symlink cannot redirect a write')
    call('disable',a)
    check(call('launch',a,prefix,engine)['mode']=='off' and ini_a.read_bytes()==bytes_a, 'disable retains snapshots without touching children')
    call('enable',a,'{"filter":"nearest","maxfps":30}')
    fresh_support=tmp/'first-run-support'
    check(call('status',b,extra={'CYDER_SUPPORT':str(fresh_support)})['mode']=='off' and not fresh_support.exists(), 'first-run status is read-only without existing support root')
    call('enable',b,'{"filter":"nearest","maxfps":60}',extra={'CYDER_SUPPORT':str(fresh_support)})
    alternate=call('launch',b,prefix,engine,extra={'CYDER_SUPPORT':str(fresh_support)})
    check(alternate['dllPath']!=out_a['dllPath'], 'two isolated support namespaces yield distinct explicit external DLL paths')
    check(all((p.stat().st_mode&0o777)==0o444 for p in (support/'directdraw/payloads').rglob('*') if p.is_file()), 'versioned payload files are verified read-only')
    check(all((p.stat().st_mode&0o777)==0o444 for p in (prefix/'drive_c/CyderCncDdraw').rglob('*.ini')), 'immutable INI snapshots are read-only')

    shell=r'''
set -euo pipefail
root="$1"; a="$2"; b="$3"; other="$4"; prefix="$5"; engine="$6"; output="$7"
seed_aliases() {
 export CYDER_DDRAW_PATH='' cyder_ddraw_path='foreign-sentinel' CyDeR_DdRaW_PaTh=''
 export CNC_DDRAW_CONFIG_FILE='' cnc_ddraw_config_file='foreign-sentinel' CnC_DdRaW_CoNfIg_FiLe=''
}
assert_no_pair_aliases() {
 /usr/bin/python3 -c 'import os; reserved={"CYDER_DDRAW_PATH","CNC_DDRAW_CONFIG_FILE"}; assert not any(k.upper() in reserved for k in os.environ); assert os.environ["CYDER_DDRAW_PATH_EXTRA"]=="keep"; assert os.environ["cnc_ddraw_config_file_extra"]=="keep"'
}
assert_final_pair() {
 /usr/bin/python3 -c 'import os; reserved={"CYDER_DDRAW_PATH","CNC_DDRAW_CONFIG_FILE"}; assert {k for k in os.environ if k.upper() in reserved}==reserved; assert os.environ["CYDER_DDRAW_PATH"].startswith("Z:"); assert os.environ["CNC_DDRAW_CONFIG_FILE"].startswith("C:"); assert os.environ["CYDER_DDRAW_PATH_EXTRA"]=="keep"; assert os.environ["cnc_ddraw_config_file_extra"]=="keep"'
}
export CYDER_DDRAW_PATH_EXTRA=keep cnc_ddraw_config_file_extra=keep
seed_aliases
# Negative control: the fixture really exports aliases, including duplicate empty values.
/usr/bin/python3 -c 'import os; assert len([k for k in os.environ if k.upper() in {"CYDER_DDRAW_PATH","CNC_DDRAW_CONFIG_FILE"}])==6'
source "$root/scripts/cyder-common.sh"
assert_no_pair_aliases
export CYDER_SCRIPTS="$root/scripts" CYDER_GRAPHICS_PREFERENCE=wined3d
export CYDER_CAPTURE_WINE_LOG=0 CYDER_WINE_DIAGNOSTICS=quiet CYDER_SESSION_GUARD=0 CYDER_MSYNC=1 CYDER_ESYNC=0 CYDER_POWER_MODE=normal CYDER_WINE_DETACH=0 CYDER_SCROLLING_PREFERENCE=unmanaged
export WINEDLLOVERRIDES='mscoree='
export CYDER_DDRAW_PATH='inherited-foreign' CNC_DDRAW_CONFIG_FILE='inherited-foreign'
cyder_load_game_settings() { :; }
cyder_apply_user_settings() { assert_no_pair_aliases; test -z "${CYDER_DDRAW_PATH:-}"; test -z "${CNC_DDRAW_CONFIG_FILE:-}"; test "$WINEDLLOVERRIDES" = mscoree=; }
cyder_configure_compatdb() { :; }
cyder_apply_moltenvk_os_floor() { :; }
cyder_apply_moltenvk_variant_from_preference() { :; }
cyder_apply_gptk_launch_environment() { :; }
cyder_validate_moltenvk_for_backend() { :; }
cyder_wine_is_crossover_frontend() { return 1; }
cyder_wine_locale_exports() { :; }
cyder_apply_scrolling_for_exe() { assert_no_pair_aliases; test -z "${CYDER_DDRAW_PATH:-}"; test -z "${CNC_DDRAW_CONFIG_FILE:-}"; }
cyder_launch_preparation_drain() { assert_no_pair_aliases; test -z "${CYDER_DDRAW_PATH:-}"; test -z "${CNC_DDRAW_CONFIG_FILE:-}"; }
cyder_exec_wine() {
 test "$CYDER_EXECUTION_FINAL" = 1
 test "$PWD" -ef "$(dirname "$2")"
 test "$3" = 'argument with spaces'
 if [[ "$2" == "$other" ]]; then
  assert_no_pair_aliases
  test -z "${CYDER_DDRAW_PATH:-}"; test -z "${CNC_DDRAW_CONFIG_FILE:-}"; test "$WINEDLLOVERRIDES" = mscoree=
 else
  test -n "$CYDER_DDRAW_PATH"; test -n "$CNC_DDRAW_CONFIG_FILE"; test "$WINEDLLOVERRIDES" = 'mscoree=;ddraw=n'
  assert_final_pair
  # A normal child sees exactly the final game's paired configuration.
  /bin/bash -c 'test -n "$CYDER_DDRAW_PATH"; test -n "$CNC_DDRAW_CONFIG_FILE"; printf "%s\n" "$CNC_DDRAW_CONFIG_FILE"' >>"$output"
 fi
}
CYDER_LAUNCH_PREPARATION_PHASE=prepare
seed_aliases
cyder_prepare_game_launch_settings "$engine/bin/wine" "$engine" "$prefix" "$a"
test -z "$CYDER_CNC_GAME_CONFIG"; test -z "$CYDER_CNC_GAME_DLL"
cyder_run_wine_exe "$engine/bin/wine" "$a" "$prefix" 'argument with spaces'
CYDER_LAUNCH_PREPARATION_PHASE=final
for exe in "$a" "$b" "$other"; do
 seed_aliases
 if [[ "$exe" == "$other" ]]; then cp "$prefix/cxbottle.conf" "$output.after-cnc"; fi
 cyder_prepare_game_launch_settings "$engine/bin/wine" "$engine" "$prefix" "$exe"
 test -z "${CYDER_DDRAW_PATH:-}"; test -z "${CNC_DDRAW_CONFIG_FILE:-}"
 cyder_run_wine_exe "$engine/bin/wine" "$exe" "$prefix" 'argument with spaces'
done
# Direct repeated planner/apply use also retracts only its own injection.
cyder_prepare_cnc_game "$a" "$prefix" "$engine";seed_aliases;cyder_apply_cnc_game_environment
assert_final_pair
seed_aliases
cyder_prepare_cnc_game "$other" "$prefix" "$engine";cyder_apply_cnc_game_environment
test -z "${CYDER_DDRAW_PATH:-}";test -z "${CNC_DDRAW_CONFIG_FILE:-}";test "$WINEDLLOVERRIDES" = mscoree=
! cyder_game_environment_key_is_allowed CYDER_DDRAW_PATH
! cyder_game_environment_key_is_allowed CNC_DDRAW_CONFIG_FILE
for key in cyder_ddraw_path CyDeR_DdRaW_PaTh cnc_ddraw_config_file CnC_DdRaW_CoNfIg_FiLe; do
 ! cyder_game_environment_key_is_allowed "$key"
done
assert_no_pair_aliases
# Reduced old launcher fixtures can omit the helper only for a game with no rule.
mkdir "$output.no-helper"
CYDER_SCRIPTS="$output.no-helper"
cyder_prepare_cnc_game "$other" "$prefix" "$engine"
if cyder_prepare_cnc_game "$a" "$prefix" "$engine"; then exit 1; fi
'''
    result=subprocess.run(['/bin/bash','-c',shell,'_',str(ROOT),str(a),str(b),str(other),str(prefix),str(engine),str(tmp/'child-env')],env=env,capture_output=True,text=True)
    check(result.returncode==0, 'production preparation/final dispatcher and sequential environment isolation: '+result.stderr)
    child=(tmp/'child-env').read_text().splitlines()
    check(len(child)==2 and child[0]!=child[1], 'ordinary children inherit each final launch private INI')
    check(True, 'real child environment has no aliases in bootstrap/preparation/off and exactly one uppercase pair in final/reusable shell')
    saved_settings=tmp/'alias-settings.json'
    saved_settings.write_text(json.dumps({'perProfile':{aid:{'environment':{**{key:'' for key in aliases},'CYDER_DDRAW_PATH_EXTRA':'keep'}}}}))
    loader_shell=r"""
set -euo pipefail
root="$1"; exe="$2"; settings="$3"; engine="$4"
source "$root/scripts/cyder-common.sh"
export CYDER_SCRIPTS="$root/scripts"
cyder_launch_settings_path() { printf '%s\n' "$settings"; }
cyder_load_game_settings "$exe" "$engine"
test "$CYDER_GAME_SETTINGS_FOUND" = 1
/usr/bin/python3 -c 'import os; assert not any(k.upper() in {"CYDER_DDRAW_PATH","CNC_DDRAW_CONFIG_FILE"} for k in os.environ); assert os.environ["CYDER_DDRAW_PATH_EXTRA"]=="keep"'
"""
    loaded=subprocess.run(['/bin/bash','-c',loader_shell,'_',str(ROOT),str(a),str(saved_settings),str(engine)],env=env,capture_output=True,text=True)
    check(loaded.returncode==0, 'real saved per-game environment loader filters lower/mixed internal names while preserving unrelated entry: '+loaded.stderr)
    check((tmp/'child-env.after-cnc').read_bytes()==bottle_before, 'CNC launches do not alter shared bottle registry environment')
    check(all(tree(p.parent)==before[str(p.parent)] for p in games), 'all original game contents unchanged after enabled/off/parallel launches')

    # Preserve the old manager's real receipt/restore behavior, then explicitly
    # transition an off legacy copy to external rules without deleting backups.
    legacy_dir=tmp/'legacy'
    call('copy',a,legacy_dir,manager=LEGACY)
    lexe=legacy_dir/'game.exe'
    check(call('status',lexe)['mode']=='legacy', 'existing managed copies are explicitly classified legacy')
    call('enable',lexe,accept=False)
    receipt=(legacy_dir/'.cyder-cnc-ddraw/receipt.json').read_bytes()
    call('restore',lexe)
    check(call('status',lexe)['legacyMode']=='off', 'explicit restore runs original helper')
    call('enable',lexe,'{"filter":"bilinear","maxfps":60}')
    check(call('launch',lexe,prefix,engine)['mode']=='on', 'restored legacy copy can enter external mode')
    check((legacy_dir/'.cyder-cnc-ddraw/receipt.json').read_bytes()==receipt and not (legacy_dir/'ddraw.dll').exists(), 'legacy receipt retained and original DLL restoration retained')
    call('disable',lexe)
    check(call('status',lexe)['mode']=='off' and call('status',lexe)['legacyMode']=='off', 'external rule-off keeps restored legacy state explicit')
    call('enable',lexe,manager=LEGACY)
    check(call('status',lexe)['mode']=='legacy' and call('status',lexe)['legacyMode']=='on', 're-enabled legacy DLL is surfaced instead of reinterpreted as external')
    call('launch',lexe,prefix,engine,accept=False)
    call('restore',lexe)
    check(call('launch',lexe,prefix,engine)['mode']=='off', 'restoring legacy again preserves the external off rule')

print(json.dumps({'status':'PASS_OFFLINE_PER_LAUNCH_CNC_BACKEND','checks':len(checks),'assertions':checks,'WineOrUIExecuted':False,'realGameOrExistingStateUsed':False},indent=2))
