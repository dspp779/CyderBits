import json, os, pathlib, plistlib, shutil, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
children = []

def start(mode, case, label):
    output = root / case / label
    output.mkdir(parents=True, exist_ok=True)
    case_app = root / case / 'Cyder.app'
    identity = 'local.cy.' + root.name.split('.')[-1] + '.' + case
    if case == 'unavailable':
        identity += '.' + 'x' * 104  # Deterministic sentinel bind failure.
    if not case_app.exists():
        shutil.copytree(root / 'Cyder.app', case_app)
        info = case_app / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = identity
        info.write_bytes(plistlib.dumps(data))
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none', str(case_app)], check=True)
    env = dict({k: v for k, v in os.environ.items() if not k.startswith('CYDER_')}, CYDER_FIXTURE_MODE=mode, CYDER_FIXTURE_OUTPUT=str(output),
               CYDER_SUPPORT=str(root / case / 'support'), CYDER_RUNTIME_ROOT=str(root / case / 'runtime'),
               CYDER_BUNDLE_ID=identity)
    log = (output / 'process.log').open('wb')
    child = subprocess.Popen([str(case_app / 'Contents/MacOS/CyderSwift')], env=env, stdout=log, stderr=subprocess.STDOUT)
    children.append((child, log))
    return child, output

def finish(child, output, seed=False):
    code = child.wait(timeout=30)
    assert code == 0, (code, str(output))
    assert not (output / 'failed.json').exists(), str(output)
    if seed:
        return json.loads((output / 'seed.json').read_text())
    state = json.loads((output / 'terminated.json').read_text())
    assert state['expected'], state
    if state['mode'] != 'secondary':
        expected = ['unavailable', 'read-only-library'] if state['mode'] == 'unavailable' else ['library', 'settings', 'reopen']
        assert state['actions'][:len(expected)] == expected, state
        assert state['actions'][-1].startswith('quit-'), state
        assert 0 <= state['quitSeconds'] < 8, state
    return state

def until(predicate, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.03)
    raise AssertionError('integration observation deadline')

def tickets(case):
    return list((root / case / 'support/execution-owners').glob('*.json'))

try:
    for mode in ['menu', 'direct', 'runloop', 'unavailable', 'slowlog']:
        child, output = start(mode, mode, 'primary')
        state = finish(child, output)
        assert not tickets(mode), 'browsing generated a launch'
        assert not (root / mode / 'support/request-journal').exists(), 'requests must not be persisted'
        if mode == 'slowlog':
            logs = root / mode / 'support/Logs'
            assert (output / 'diagnostic-blocked.json').exists(), 'diagnostic fault was not entered'
            assert not list((logs / 'sessions').glob('*.log')), 'diagnostic initializer passed the blocked read'
        print('PASS full app entry:', mode, state['actions'], 'quit_seconds=', state['quitSeconds'], flush=True)
    seed, seed_output = start('seed', 'recovery', 'seed')
    ids = finish(seed, seed_output, seed=True)
    primary, primary_output = start('forward', 'recovery', 'primary')
    until(lambda: (primary_output / 'ready.json').exists() or primary.poll() is not None)
    assert primary.poll() is None, str(primary_output)
    legacy = [root / 'recovery/support/request-journal', root / 'recovery/support/request-outbox']
    until(lambda: not any(path.exists() for path in legacy))
    assert not tickets('recovery'), 'legacy request was replayed'
    # The secondary exits 0 only after the primary accepted its forwarded request.
    secondary, secondary_output = start('secondary', 'recovery', 'secondary')
    finish(secondary, secondary_output)
    (primary_output / 'continue').write_text('quit\n')
    finish(primary, primary_output)
    # Reopen the whole app again: nothing was persisted, so nothing can replay.
    restarted, restarted_output = start('direct', 'recovery', 'restarted')
    finish(restarted, restarted_output)
    assert not any(path.exists() for path in legacy), 'requests were persisted again'
    assert not tickets('recovery'), 'unexpected native executor request'
    (root / 'complete').write_text('complete\n')
    print('PASS full app: secondary forwarding accepted once, legacy rc.1 request files removed without replay, reopen without replay, menu/AppKit quit', flush=True)
finally:
    for child, log in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        log.close()
