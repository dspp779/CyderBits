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
        expected = ['unavailable', 'read-only-library'] if state['mode'] == 'unavailable' else ['library', 'settings', 'requests', 'reopen']
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

def records(case):
    path = root / case / 'support/request-journal/requests-v1.json'
    return json.loads(path.read_text())['records'] if path.exists() else {}

try:
    for mode in ['menu', 'direct', 'runloop', 'unavailable']:
        child, output = start(mode, mode, 'primary')
        state = finish(child, output)
        assert records(mode) == {}, 'browsing generated a launch request'
        if mode == 'unavailable':
            assert not (root / mode / 'support/request-journal').exists(), 'read-only fallback acquired journal'
        print('PASS full app entry:', mode, state['actions'], 'quit_seconds=', state['quitSeconds'], flush=True)
    seed, seed_output = start('seed', 'recovery', 'seed')
    ids = finish(seed, seed_output, seed=True)
    primary, primary_output = start('forward', 'recovery', 'primary')
    until(lambda: (primary_output / 'ready.json').exists() or primary.poll() is not None)
    assert primary.poll() is None, str(primary_output)
    before = records('recovery')
    assert before[ids['queued']]['phase'] == 'awaitingUserResume', before
    assert before[ids['dispatch']]['phase'] == 'uncertain', before
    secondary, secondary_output = start('secondary', 'recovery', 'secondary')
    finish(secondary, secondary_output)
    until(lambda: any(r.get('outcome') == 'ui-presented' for r in records('recovery').values()))
    current = records('recovery')
    assert len(current) == 3 and sum(r.get('outcome') == 'ui-presented' for r in current.values()) == 1, current
    assert current[ids['queued']] == before[ids['queued']]
    assert current[ids['dispatch']] == before[ids['dispatch']]
    (primary_output / 'continue').write_text('quit\n')
    finish(primary, primary_output)
    # Reopen the whole app again. Historical requests stay non-dispatchable.
    restarted, restarted_output = start('direct', 'recovery', 'restarted')
    finish(restarted, restarted_output)
    after = records('recovery')
    assert set(after) == set(current), 'reopen created or replayed requests'
    assert after[ids['queued']] == current[ids['queued']]
    assert after[ids['dispatch']] == current[ids['dispatch']]
    assert not list((root / 'recovery/support/execution-owners').glob('*.json')), 'unexpected native executor request'
    (root / 'complete').write_text('complete\n')
    print('PASS full app: durable secondary forwarding once, historical queued/dispatch recovery, reopen without replay, menu/AppKit quit', flush=True)
finally:
    for child, log in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        log.close()
