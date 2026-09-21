from pathlib import Path
import json, os, subprocess, sys, time, uuid

root, helper, scripts, native = map(Path, sys.argv[1:5])
executor = Path(os.environ.get('CYDER_EXECUTION_HELPER', str(helper)))
root.mkdir(parents=True, exist_ok=True)
ledger = root / 'owners'
ledger.mkdir(mode=0o700)
processes = []


def wait(condition, message, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if condition():
            return
        time.sleep(.02)
    raise AssertionError(message)


def case(name):
    directory = root / name
    for child in ['prefix', 'support', 'runtime/bin']:
        (directory / child).mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700)
    (directory / 'runtime/bin/wine').symlink_to(native)
    # Inert GPTK files avoid discovering the host's CrossOver installation.
    gptk = directory / 'support/runtime/apple_gptk'
    (gptk / 'external/D3DMetal.framework').mkdir(parents=True)
    (gptk / 'external/libd3dshared.dylib').write_text('inert fixture, never loaded')
    (directory / 'runtime/lib64').mkdir()
    (directory / 'runtime/lib64/apple_gptk').symlink_to(gptk)
    (directory / 'inert.exe').touch()
    return directory


def reserve(directory, handoff=True, prefix=None, executable=native, global_scope=False):
    prefix = prefix or directory / 'prefix'
    command = [str(helper), '--prepare-global' if global_scope else '--prepare', str(ledger), str(prefix)]
    if handoff: command += [str(executable), str(directory / 'pid')]
    return subprocess.check_output(command, text=True, timeout=10).strip()


def receipt(ticket):
    return json.loads((ledger / (ticket + '.json')).read_text())


def start(directory, ticket, command):
    env = os.environ | dict(SOURCE_SCRIPTS=str(scripts), CYDER_SCRIPTS=str(scripts), TEST_ROOT=str(directory),
        CYDER_SUPPORT=str(directory / 'support'), CYDER_RUNTIME_ROOT=str(directory / 'runtime'),
        CYDER_WINE_DETACH='1', CYDER_WINE_PID_FILE=str(directory / 'pid'),
        CYDER_WINE_RESULT_FILE=str(directory / 'result'), CYDER_SESSION_GUARD='0',
        CYDER_CAPTURE_WINE_LOG='1', CYDER_POWER_MODE='normal')
    with (directory / ('owner-' + ticket + '.log')).open('w') as output:
        process = subprocess.Popen([str(executor), '--execution-owner', str(ledger), ticket, '--'] + command,
                                   env=env, stdout=output, stderr=subprocess.STDOUT)
    processes.append(process)
    return process


def recover():
    subprocess.run([str(helper), '--recover', str(ledger)], check=True, timeout=10)


try:
    delayed = case('delayed')
    script = delayed / 'launch.sh'
    script.write_text('''#!/bin/bash
set -e
source "$SOURCE_SCRIPTS/cyder-common.sh"
if [[ "${SOURCE_SCRIPTS##*/}" == ogom-scripts ]]; then
  cyder_init_paths "${SOURCE_SCRIPTS%/*}"
else
  cyder_init_paths "$SOURCE_SCRIPTS"
fi
cyder_sentinel_attach() { :; }
# Stall the real quiet-log wrapper before its FIFO is ready. The actual
# cyder_exec_wine and the new native bridge remain entirely unmodified.
mkfifo() {
  printf 'entered\\n' > "$TEST_ROOT/wrapper.entered"
  while [[ ! -e "$TEST_ROOT/log.release" ]]; do sleep 0.02; done
  /usr/bin/mkfifo "$@"
}
cyder_run_wine_exe "$TEST_ROOT/runtime/bin/wine" "$TEST_ROOT/inert.exe" "$TEST_ROOT/prefix"
''')
    ticket = reserve(delayed)
    owner = start(delayed, ticket, ['/bin/bash', str(script)])
    wait(lambda: (delayed / 'wrapper.entered').exists(), 'formal log wrapper never entered')
    time.sleep(.3)
    assert owner.poll() is None and receipt(ticket)['phase'] == 'active'
    assert not (delayed / 'pid').exists() and not (delayed / 'native.entered').exists()
    recover()
    conflict = start(delayed, reserve(delayed, False), ['/usr/bin/true'])
    wait(lambda: conflict.poll() is not None, 'same-prefix conflict did not return')
    assert conflict.returncode == 75
    independent = case('independent')
    other = start(independent, reserve(independent, False), ['/usr/bin/true'])
    wait(lambda: other.poll() is not None, 'independent environment blocked')
    assert other.returncode == 0
    (delayed / 'log.release').touch()
    wait(lambda: (delayed / 'native.entered').exists() and owner.poll() is not None,
         'native spawn handoff did not release the outer owner')
    assert owner.returncode == 0
    state = receipt(ticket)
    native_pid, architecture = (delayed / 'native.entered').read_text().split()
    assert architecture == 'x86_64'
    assert int((delayed / 'pid').read_text()) == int(native_pid) == state['nativeSpawn']['process']['pid']
    assert state['phase'] == 'handedOff' and state['nativeSpawn']['phase'] == 'spawned'
    assert state['nativeSpawn']['process']['started'] > 0
    duplicate = subprocess.run([str(executor), '--execution-wine', str(ledger), ticket, '--', str(native)],
                               env=os.environ | {'WINEPREFIX': str(delayed / 'prefix')}, timeout=10)
    assert duplicate.returncode == 75
    recover()
    following = start(delayed, reserve(delayed, False), ['/usr/bin/true'])
    wait(lambda: following.poll() is not None, 'following launch waited for game exit')
    assert following.returncode == 0 and not (delayed / 'native.release').exists()
    (delayed / 'native.release').touch()
    wait(lambda: (delayed / 'result').exists(), 'formal supervisor lost root result')
    wait(lambda: receipt(ticket).get('nativeSpawn', {}).get('phase') == 'exited', 'native result not persisted')
    state = receipt(ticket)
    assert state['phase'] == 'finished' and state['nativeSpawn']['status'] == 53
    assert state['nativeSpawn']['signalled'] is False
    result = (delayed / 'result').read_text()
    assert 'exit_status=53' in result and f'pid={native_pid}' in result
    print('PASS native handoff: formal log wrapper stall retains scope, no early PID, recovery and independent prefix progress, actual x86_64 child birth, one-use bridge, next same-prefix operation before game exit, exact root result', flush=True)

    refused = case('runtime-refused')
    refused_link = refused / 'runtime/lib64/apple_gptk'
    refused_link.unlink()
    refused_script = refused / 'launch.sh'
    refused_script.write_text(script.read_text().split('cyder_sentinel_attach()')[0] + '''
cyder_apply_gptk_launch_environment "$TEST_ROOT/runtime"
printf 'changed\\n' > "$TEST_ROOT/runtime.changed"
''')
    refused_owner = start(refused, reserve(refused), ['/bin/bash', str(refused_script)])
    wait(lambda: refused_owner.poll() is not None, 'prefix-only runtime attempt did not settle')
    assert not refused_link.is_symlink() and not (refused / 'runtime.changed').exists(), 'prefix-only launch modified shared GPTK runtime'
    assert refused_owner.returncode == 75
    print('PASS shared runtime: prefix-only owner refuses changed GPTK discovery without modifying shared tree', flush=True)

    runtime = case('runtime-global')
    runtime_link = runtime / 'runtime/lib64/apple_gptk'
    runtime_link.unlink()
    molten = runtime / 'runtime/lib/wine/x86_64-unix'
    molten.mkdir(parents=True)
    for version in ['1.4.2', '1.2.10']:
        (molten / f'libMoltenVK-{version}.dylib').touch()
    (molten / 'libMoltenVK.dylib').write_text('cyder-moltenvk-timeline-wait-poll\n')
    molten_link = molten / 'libMoltenVK.real.dylib'
    molten_link.symlink_to('libMoltenVK-1.2.10.dylib')
    molten_script = runtime / 'launch.sh'
    # Inert dylib headers use a validation-tool substitute; actual settings,
    # symlink mutation, authority and final native executor remain formal.
    preamble = '''
export CYDER_MOLTENVK_VARIANT_PREFERENCE=1.4.2 CYDER_MOCK_MACOS=13.0
otool() { printf '%s\\n' '@loader_path/libMoltenVK.real.dylib'; }
'''
    prefix_script = runtime / 'prefix-attempt.sh'
    prefix_script.write_text(script.read_text().split('cyder_sentinel_attach()')[0] + preamble + '''
cyder_apply_moltenvk_variant_from_preference "$TEST_ROOT/runtime"
''')
    prefix_owner = start(runtime, reserve(runtime, False), ['/bin/bash', str(prefix_script)])
    wait(lambda: prefix_owner.poll() is not None, 'prefix-only MoltenVK owner did not return')
    assert prefix_owner.returncode == 75 and os.readlink(molten_link) == 'libMoltenVK-1.2.10.dylib'
    print('PASS MoltenVK native scope: non-handoff prefix owner cannot switch the shared runtime', flush=True)
    molten_script.write_text(preamble + script.read_text())
    runtime_ticket = reserve(runtime, global_scope=True)
    assert receipt(runtime_ticket)['schema'] == 2
    old_executor = os.environ.get('CYDER_TEST_OLD_EXECUTOR')
    if old_executor:
        old_attempt = subprocess.run([old_executor, '--execution-owner', str(ledger), runtime_ticket,
                                      '--', '/usr/bin/touch', str(runtime / 'old-helper-spawned')], timeout=10)
        assert old_attempt.returncode == 75 and not (runtime / 'old-helper-spawned').exists()
        assert receipt(runtime_ticket)['phase'] == 'prepared'
        print('PASS legacy helper: schema 2 global authority refused without starting a child or altering the ticket', flush=True)
    runtime_owner = start(runtime, runtime_ticket, ['/bin/bash', str(molten_script)])
    wait(lambda: (runtime / 'wrapper.entered').exists(), 'global runtime preparation did not reach formal launch')
    assert runtime_link.resolve() == (runtime / 'support/runtime/apple_gptk').resolve()
    assert os.readlink(molten_link) == 'libMoltenVK-1.4.2.dylib'
    assert receipt(runtime_ticket)['requiresGlobalScope'] is True and receipt(runtime_ticket)['scope'] is not None
    runtime_conflict = start(independent, reserve(independent, False), ['/usr/bin/true'])
    wait(lambda: runtime_conflict.poll() is not None, 'global runtime conflict did not return')
    assert runtime_conflict.returncode == 75
    recover()
    assert receipt(runtime_ticket)['phase'] == 'active'
    (runtime / 'log.release').touch()
    wait(lambda: runtime_owner.poll() is not None and (runtime / 'native.entered').exists(), 'global runtime launch did not hand off')
    assert runtime_owner.returncode == 0 and receipt(runtime_ticket)['phase'] == 'handedOff'
    following_runtime = start(independent, reserve(independent, False), ['/usr/bin/true'])
    wait(lambda: following_runtime.poll() is not None, 'global runtime barrier survived actual owner return')
    assert following_runtime.returncode == 0
    (runtime / 'native.release').touch()
    wait(lambda: (runtime / 'result').exists(), 'global runtime native result lost')
    assert receipt(runtime_ticket)['nativeSpawn']['status'] == 53
    print('PASS shared runtime: global native owner prepares isolated GPTK and MoltenVK, blocks other prefixes through spawn, preserves prefix identity, releases after Bash return while child survives', flush=True)

    late = case('late')
    late_script = late / 'launch.sh'
    late_script.write_text('''#!/bin/bash
(
  while [[ ! -e "$TEST_ROOT/bridge.release" ]]; do sleep 0.02; done
  WINEPREFIX="$TEST_ROOT/prefix" "$CYDER_EXECUTION_OWNER_HELPER" --execution-wine "$CYDER_EXECUTION_OWNER_ROOT" "$CYDER_EXECUTION_OWNER_TICKET" -- "$TEST_ROOT/runtime/bin/wine"
  printf '%s\\n' "$?" > "$TEST_ROOT/bridge.result"
) &
exit 0
''')
    late_ticket = reserve(late)
    late_owner = start(late, late_ticket, ['/bin/bash', str(late_script)])
    wait(lambda: late_owner.poll() is not None, 'early-returning shell did not settle')
    assert late_owner.returncode == 75 and receipt(late_ticket)['phase'] == 'finished'
    (late / 'bridge.release').touch()
    wait(lambda: (late / 'bridge.result').exists(), 'late bridge failed to finish')
    assert (late / 'bridge.result').read_text().strip() == '75'
    assert not (late / 'native.entered').exists() and not (late / 'pid').exists()
    print('PASS late bridge: Bash return without handoff is unconfirmed, its delayed final wrapper cannot claim or spawn after settlement', flush=True)

    abandoned = case('abandoned')
    abandoned_script = abandoned / 'launch.sh'; abandoned_script.write_text(script.read_text())
    abandoned_ticket = reserve(abandoned)
    abandoned_owner = start(abandoned, abandoned_ticket, ['/bin/bash', str(abandoned_script)])
    wait(lambda: (abandoned / 'wrapper.entered').exists(), 'pre-spawn crash fixture did not stall')
    assert receipt(abandoned_ticket)['owner']['pid'] == abandoned_owner.pid and abandoned_owner.poll() is None
    # This is our own unreaped Popen child; its PID cannot be recycled before
    # our wait. Never signal a PID obtained from a broad process-name search.
    abandoned_owner.kill(); assert abandoned_owner.wait(timeout=10) == -9
    recover()
    assert receipt(abandoned_ticket)['phase'] == 'uncertain'
    (abandoned / 'log.release').touch()
    wait(lambda: (abandoned / 'result').exists(), 'orphan wrapper did not return after owner loss')
    assert not (abandoned / 'native.entered').exists() and not (abandoned / 'pid').exists()
    assert 'exit_status=75' in (abandoned / 'result').read_text()
    print('PASS owner crash before spawn: exact owned native executor killed, recovery retains uncertainty, late formal wrapper refuses to start a child', flush=True)

    handed = case('handed')
    (handed / 'log.release').touch()
    handed_script = handed / 'launch.sh'
    handed_script.write_text(script.read_text() + '''
printf 'waiting\\n' > "$TEST_ROOT/parent.waiting"
while [[ ! -e "$TEST_ROOT/parent.release" ]]; do sleep 0.02; done
printf 'finished\\n' > "$TEST_ROOT/parent.finished"
''')
    handed_ticket = reserve(handed)
    handed_owner = start(handed, handed_ticket, ['/bin/bash', str(handed_script)])
    wait(lambda: (handed / 'parent.waiting').exists() and (handed / 'native.entered').exists(), 'post-spawn owner fixture did not stall')
    assert receipt(handed_ticket)['phase'] == 'handedOff'
    assert receipt(handed_ticket)['owner']['pid'] == handed_owner.pid and handed_owner.poll() is None
    handed_owner.kill(); assert handed_owner.wait(timeout=10) == -9
    recover()
    assert receipt(handed_ticket)['phase'] == 'handedOff'
    next_owner = start(handed, reserve(handed, False), ['/usr/bin/true'])
    wait(lambda: next_owner.poll() is not None, 'confirmed native handoff stranded its scope after owner crash')
    assert next_owner.returncode == 0 and not (handed / 'native.release').exists()
    (handed / 'parent.release').touch(); (handed / 'native.release').touch()
    wait(lambda: (handed / 'parent.finished').exists(), 'known orphan Bash fixture did not acknowledge release')
    wait(lambda: (handed / 'result').exists(), 'surviving native child result was lost')
    assert 'exit_status=53' in (handed / 'result').read_text()
    recover()
    assert receipt(handed_ticket)['phase'] == 'finished' and receipt(handed_ticket)['nativeSpawn']['status'] == 53
    assert receipt(handed_ticket).get('status') is None  # the killed owner's Bash result remains unknown
    print('PASS owner crash after spawn: actual native child survives, persisted handoff permits independent new scope ownership, root exit recovers without inventing a Bash result', flush=True)

    denied = case('denied')
    (denied / 'log.release').touch()
    denied_binary = denied / 'nonexecutable'
    denied_binary.write_bytes(native.read_bytes()); denied_binary.chmod(0o600)
    (denied / 'runtime/bin/wine').unlink(); (denied / 'runtime/bin/wine').symlink_to(denied_binary)
    denied_script = denied / 'launch.sh'; denied_script.write_text(script.read_text())
    denied_ticket = reserve(denied, executable=denied_binary)
    denied_owner = start(denied, denied_ticket, ['/bin/bash', str(denied_script)])
    wait(lambda: denied_owner.poll() is not None and (denied / 'result').exists(), 'failed native spawn was masked or left a waiting supervisor')
    assert denied_owner.returncode == 75
    assert receipt(denied_ticket)['phase'] == 'finished' and receipt(denied_ticket)['nativeSpawn']['phase'] == 'failed'
    assert not (denied / 'pid').exists() and not (denied / 'native.entered').exists()
    assert 'exit_status=75' in (denied / 'result').read_text()
    print('PASS native spawn error: nonexecutable Mach-O refuses before child creation, publishes no PID, one-use failure and supervisor exit code survive cleanup', flush=True)

    manager = case('taskmgr')
    manager_script = manager / 'launch.sh'
    manager_script.write_text(script.read_text().split('cyder_sentinel_attach()')[0] + '''
# Retain the formal frontend reader and executor while adding a controlled
# pre-spawn stall and a fixture-only acknowledgement of the detached result.
eval "$(declare -f cyder_wine_frontend_args | sed '1s/cyder_wine_frontend_args/cyder_test_frontend_original/')"
cyder_wine_frontend_args() {
  printf 'entered\\n' > "$TEST_ROOT/frontend.entered"
  while [[ ! -e "$TEST_ROOT/frontend.release" ]]; do sleep 0.02; done
  cyder_test_frontend_original "$@"
}
eval "$(declare -f cyder_exec_wine | sed '1s/cyder_exec_wine/cyder_test_exec_original/')"
cyder_exec_wine() {
  local result=0
  cyder_test_exec_original "$@" || result=$?
  printf '%s\\n' "$result" > "$TEST_ROOT/taskmgr.result"
  return "$result"
}
cyder_open_prefix_taskmgr "$TEST_ROOT/runtime/bin/wine" "$TEST_ROOT/prefix"
''')
    manager_ticket = reserve(manager)
    manager_owner = start(manager, manager_ticket, ['/bin/bash', str(manager_script)])
    wait(lambda: (manager / 'frontend.entered').exists(), 'formal task manager frontend never entered')
    time.sleep(.3)
    assert manager_owner.poll() is None and receipt(manager_ticket)['phase'] == 'active', 'task manager released authority before its final spawn'
    assert not (manager / 'pid').exists() and not (manager / 'native.entered').exists()
    recover()
    manager_conflict = start(manager, reserve(manager, False), ['/usr/bin/true'])
    wait(lambda: manager_conflict.poll() is not None, 'task manager scope conflict did not return')
    assert manager_conflict.returncode == 75
    (manager / 'frontend.release').touch()
    wait(lambda: manager_owner.poll() is not None and (manager / 'native.entered').exists(), 'task manager failed to hand off actual native spawn')
    assert manager_owner.returncode == 0 and receipt(manager_ticket)['phase'] == 'handedOff'
    assert receipt(manager_ticket)['nativeSpawn']['process']['pid'] == int((manager / 'pid').read_text())
    manager_following = start(manager, reserve(manager, False), ['/usr/bin/true'])
    wait(lambda: manager_following.poll() is not None, 'task manager retained scope for its entire lifetime')
    assert manager_following.returncode == 0
    (manager / 'native.release').touch()
    wait(lambda: (manager / 'taskmgr.result').exists(), 'task manager native child did not finish')
    assert (manager / 'taskmgr.result').read_text().strip() == '53'
    assert receipt(manager_ticket)['nativeSpawn']['status'] == 53
    print('PASS task manager: formal detached tool retains ownership through stalled frontend, publishes actual native PID, releases before tool exit and preserves its result', flush=True)

    for index in range(10):
        fast = case(f'fast-{index:02}')
        (fast / 'log.release').touch(); (fast / 'native.release').touch()
        fast_script = fast / 'launch.sh'; fast_script.write_text(script.read_text())
        fast_ticket = reserve(fast)
        fast_owner = start(fast, fast_ticket, ['/bin/bash', str(fast_script)])
        wait(lambda: fast_owner.poll() is not None and (fast / 'result').exists(), 'fast native exit lost handoff/result')
        assert fast_owner.returncode == 0
        state = receipt(fast_ticket)
        assert state['phase'] == 'finished' and state['status'] == 0
        assert state['nativeSpawn']['phase'] == 'exited' and state['nativeSpawn']['status'] == 53
        assert state['nativeSpawn']['process']['started'] > 0
    print('PASS fast native exit: ten immediate x86_64 exits preserve unreaped-child identity and both native/Bash outcomes before terminal settlement', flush=True)
finally:
    safe_to_remove = True
    for directory in root.iterdir():
        if directory.is_dir() and directory != ledger:
            for marker in ['log.release', 'native.release', 'bridge.release', 'parent.release', 'frontend.release']:
                (directory / marker).touch()
    for process in processes:
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            safe_to_remove = False
            print('Fixture owner still running:', process.pid, flush=True)
    # A detached native child can outlive its outer Popen owner. Never delete
    # release markers until its persisted result and any orphan test Bash have
    # acknowledged completion, including on assertion failure.
    def detached_finished():
        for path in ledger.glob('*.json'):
            if json.loads(path.read_text()).get('nativeSpawn', {}).get('phase') in ['claiming', 'spawned']:
                return False
        return all((not (d / 'parent.waiting').exists() or (d / 'parent.finished').exists())
                   and (not (d / 'frontend.entered').exists() or (d / 'taskmgr.result').exists())
                   for d in root.iterdir() if d.is_dir())
    try: wait(detached_finished, 'detached fixture remains unconfirmed', timeout=10)
    except AssertionError:
        safe_to_remove = False
        print('Preserving fixture state for unconfirmed detached work:', root, flush=True)
    if safe_to_remove: (root / 'fixture-safe-to-remove').touch()
