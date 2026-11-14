#!/usr/bin/env python3
"""Read Instruments exports to measure frame stalls in a Wine game.

Export the tables first (see references/macos-controls.md):

  xcrun xctrace export --input run.trace --toc > toc.xml
  xcrun xctrace export --input run.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="ca-client-present-request"]' > presents.xml
  xcrun xctrace export --input run.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > profile.xml

Commands:

  start   TOC.xml                      print the trace start as epoch seconds
  gaps    PRESENTS.xml PID T0 [N]      longest gaps between the game's presents
  bins    PRESENTS.xml PID T0 A B      presents per 200 ms from epoch A to B
  threads PROFILE.xml PID T0 A B       on-CPU samples per thread in [A, B]
  where   PROFILE.xml PID T0 A B TID [LO-HI ...]
          for one thread: samples whose stack touches each address range
          (for example a library's __TEXT range from vmmap)

Times are epoch seconds so they line up with guarded-key's down_at.
"""
import collections
import datetime
import re
import sys
import xml.etree.ElementTree as ET


def load(path):
    root = ET.parse(path).getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id") is not None}

    def res(e):
        return ids.get(e.get("ref"), e) if e.get("ref") else e

    return root, res


def trace_start(toc_path):
    text = open(toc_path, encoding="utf-8").read()
    m = re.search(r"<start-date>([^<]+)</start-date>", text)
    if not m:
        raise SystemExit("no start-date in TOC (trace not saved?)")
    return datetime.datetime.fromisoformat(m.group(1)).timestamp()


def present_times(path, pid, t0):
    root, res = load(path)
    tag = f"pid: {pid})"
    out = []
    for row in root.iter("row"):
        kids = [res(k) for k in row]
        if not kids or not kids[0].text:
            continue
        if any(k.tag == "thread" and tag in k.get("fmt", "") for k in kids):
            out.append(t0 + int(kids[0].text) / 1e9)
    return sorted(out)


def samples(path, pid, t0):
    """Yield (epoch, thread fmt, [frame addresses]) for one process."""
    root, res = load(path)
    tag = f"pid: {pid})"
    for row in root.iter("row"):
        t = thread = None
        frames = []
        for k in row:
            k = res(k)
            if k.tag == "sample-time" and t is None and k.text:
                t = t0 + int(k.text) / 1e9
            elif k.tag == "thread":
                thread = k.get("fmt", "")
            elif k.tag in ("tagged-backtrace", "backtrace"):
                for f in k:
                    f = res(f)
                    if f.tag == "frame" and f.get("addr"):
                        frames.append(int(f.get("addr"), 16))
        if t is not None and thread and tag in thread:
            yield t, thread, frames


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == "start":
        print(f"{trace_start(args[0]):.3f}")
    elif cmd == "gaps":
        ts = present_times(args[0], args[1], float(args[2]))
        n = int(args[3]) if len(args) > 3 else 6
        span = ts[-1] - ts[0] if len(ts) > 1 else 0.0
        print(f"presents={len(ts)} span={span:.2f}s")
        gaps = sorted(((b - a, a) for a, b in zip(ts, ts[1:])), reverse=True)
        for g, a in gaps[:n]:
            print(f"gap {g * 1000:.0f} ms from {a:.3f} to {a + g:.3f}")
    elif cmd == "bins":
        ts = present_times(args[0], args[1], float(args[2]))
        a, b = float(args[3]), float(args[4])
        counts = collections.Counter(int((t - a) / 0.2) for t in ts if a <= t < b)
        nbins = int((b - a) / 0.2 + 0.5)
        print(" ".join(f"{a + i * 0.2:.1f}:{counts[i]}" for i in range(nbins)))
    elif cmd == "threads":
        a, b = float(args[3]), float(args[4])
        c = collections.Counter(
            th for t, th, _ in samples(args[0], args[1], float(args[2])) if a <= t <= b)
        print(f"window={b - a:.3f}s samples={sum(c.values())}")
        for th, n in c.most_common(12):
            print(f"{n:6d}  {th}")
    elif cmd == "where":
        a, b, tid = float(args[3]), float(args[4]), args[5].lower()
        ranges = []
        for spec in args[6:]:
            lo, hi = spec.split("-")
            ranges.append((spec, int(lo, 16), int(hi, 16)))
        total = 0
        hits = collections.Counter()
        for t, th, frames in samples(args[0], args[1], float(args[2])):
            if not (a <= t <= b) or tid not in th.lower():
                continue
            total += 1
            for spec, lo, hi in ranges:
                if any(lo <= v < hi for v in frames):
                    hits[spec] += 1
        print(f"thread {tid}: {total} on-CPU samples in {b - a:.3f}s")
        for spec, _, _ in ranges:
            print(f"{hits[spec]:6d}  stack touches {spec}")
    else:
        raise SystemExit(f"unknown command {cmd}\n{__doc__}")


if __name__ == "__main__":
    main(sys.argv)
