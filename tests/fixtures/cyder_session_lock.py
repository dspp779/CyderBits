from pathlib import Path
import os, subprocess, sys, time

root, common = map(Path, sys.argv[1:3])
root.mkdir(parents=True)
script = root / 'caller.sh'
script.write_text('''#!/bin/bash
set -e
source "$1"
root="$2"; mode="$3"
export CYDER_SESSION_LOCK_ATTEMPTS="${4:-250}"
if [[ "$mode" == before ]]; then
  count=0
  umask() {
    builtin umask "$@"
    if [[ $# == 1 ]]; then
      count=$((count + 1))
      if [[ "$count" == 2 ]]; then
        touch "$root/opened"
        while [[ ! -e "$root/publish" ]]; do sleep 0.02; done
      fi
    fi
  }
fi
if [[ "$mode" == occupied ]]; then
  exec 9>"$root/caller-fd"
  status=0; cyder_session_lock "$root/sessions" || status=$?
  printf 'preserved\\n' >&9
  [[ "$status" == 75 ]]
  exit 0
fi
if [[ "$mode" == counter ]]; then
  for _ in {1..10}; do
    cyder_session_lock "$root/sessions"
    value=$(cat "$root/counter")
    printf '%s\\n' "$((value + 1))" > "$root/counter"
    cyder_session_unlock
  done
  exit 0
fi
cyder_session_lock "$root/sessions" || exit $?
touch "$root/$mode.claimed"
if [[ "$mode" == fork ]]; then
  (
    touch "$root/child.entered"
    while [[ ! -e "$root/release" ]]; do sleep 0.02; done
    cyder_session_unlock
    touch "$root/child.finished"
  ) &
  exit 0
fi
if [[ "$mode" == hold ]]; then
  while [[ ! -e "$root/release" ]]; do sleep 0.02; done
fi
cyder_session_unlock
''')
processes = []
cases = []
def case(name):
    p = root / name; p.mkdir(); cases.append(p); return p

def start(p, mode, attempts=250):
    with (p / (mode + '.log')).open('a') as log:
        process = subprocess.Popen(['/bin/bash', str(script), str(common), str(p), mode, str(attempts)], stdout=log, stderr=subprocess.STDOUT)
    processes.append(process); return process

def wait(condition, message):
    end = time.monotonic() + 7
    while time.monotonic() < end:
        if condition(): return
        time.sleep(.01)
    raise AssertionError(message)

try:
    p = case('initialization')
    paused = start(p, 'before', 10)
    wait(lambda: (p/'opened').exists(), 'initializer did not pause after opening its descriptor')
    inode = (p/'sessions/.session.lock').stat().st_ino
    holder = start(p, 'hold')
    wait(lambda: (p/'hold.claimed').exists(), 'independent caller could not acquire while initializer was paused')
    (p/'publish').touch()
    assert paused.wait(timeout=5) == 75 and holder.poll() is None
    assert not (p/'before.claimed').exists(), 'late initializer stole an active lock'
    assert (p/'sessions/.session.lock').stat().st_ino == inode
    (p/'release').touch(); assert holder.wait(timeout=5) == 0
    assert start(p, 'once').wait(timeout=5) == 0
    assert (p/'sessions/.session.lock').stat().st_ino == inode, 'release replaced the shared lock inode'
    print('PASS initializer paused after open cannot steal a later live holder; persistent inode survives release and reacquisition', flush=True)

    for mode in ['before', 'hold']:
        p = case('crash-' + mode)
        owner = start(p, mode)
        marker = 'opened' if mode == 'before' else 'hold.claimed'
        wait(lambda: (p/marker).exists(), 'crash fixture did not reach its barrier')
        # Exact unreaped Popen child: no PID lookup or broad signal operation.
        owner.kill(); assert owner.wait(timeout=5) == -9
        (p/'publish').touch(); (p/'release').touch()
        assert start(p, 'once').wait(timeout=5) == 0
    print('PASS exact owned caller crash before/after acquisition leaves no stale PID lock and permits a new holder', flush=True)

    p = case('inherited')
    parent = start(p, 'fork')
    wait(lambda: (p/'child.entered').exists(), 'inherited child did not start')
    assert parent.wait(timeout=5) == 0
    assert start(p, 'blocked', 5).wait(timeout=5) == 75, 'parent exit released a child-held descriptor'
    (p/'release').touch()
    wait(lambda: (p/'child.finished').exists(), 'child did not release its inherited descriptor')
    assert start(p, 'once').wait(timeout=5) == 0
    print('PASS parent exit preserves inherited lock; only the final descriptor close permits another holder', flush=True)

    p = case('caller-fd')
    assert start(p, 'occupied').wait(timeout=5) == 0
    assert (p/'caller-fd').read_text() == 'preserved\n'
    p = case('symlink'); (p/'sessions').mkdir()
    target = p/'untouched'; target.write_text('do not change')
    (p/'sessions/.session.lock').symlink_to(target)
    assert start(p, 'once').wait(timeout=5) == 75 and target.read_text() == 'do not change'
    p = case('fifo'); (p/'sessions').mkdir(); os.mkfifo(p/'sessions/.session.lock')
    assert start(p, 'once').wait(timeout=5) == 75
    print('PASS caller FD is preserved; symlink/FIFO lock paths are refused without changing target data or blocking', flush=True)

    p = case('parallel'); (p/'counter').write_text('0\n')
    workers = [start(p, 'counter') for _ in range(4)]
    assert all(w.wait(timeout=10) == 0 for w in workers)
    assert (p/'counter').read_text() == '40\n'
    print('PASS four real shell callers preserve all forty serialized critical-section updates', flush=True)
    (root/'passed').touch()
finally:
    for p in cases:
        (p/'publish').touch(); (p/'release').touch()
    for p in processes:
        if p.poll() is None:
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait(timeout=5)
    inherited = root/'inherited'
    if (inherited/'child.entered').exists():
        wait(lambda: (inherited/'child.finished').exists(), 'inherited helper still owns a lock')
