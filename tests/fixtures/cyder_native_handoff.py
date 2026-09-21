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
    (directory / 'inert.exe').touch()
    return directory


def reserve(directory, handoff=True, prefix=None, executable=native):
    prefix = prefix or directory / 'prefix'
    command = [str(helper), '--prepare', str(ledger), str(prefix)]
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
            for marker in ['log.release', 'native.release', 'bridge.release', 'parent.release']:
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
        return all(not (d / 'parent.waiting').exists() or (d / 'parent.finished').exists()
                   for d in root.iterdir() if d.is_dir())
    try: wait(detached_finished, 'detached fixture remains unconfirmed', timeout=10)
    except AssertionError:
        safe_to_remove = False
        print('Preserving fixture state for unconfirmed detached work:', root, flush=True)
    if safe_to_remove: (root / 'fixture-safe-to-remove').touch()
