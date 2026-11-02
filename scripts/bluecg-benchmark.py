#!/usr/bin/env python3
"""Explicit-PID CPU sampling and offline frame-interval summaries."""
import argparse
import csv
import json
import math
import statistics
import subprocess
import sys
import time
from pathlib import Path


def cpu_seconds(value):
    # BSD ps TIME is [[days-]hours:]minutes:seconds[.fraction].
    days, sep, value2 = value.partition('-')
    if sep:
        value = value2
        day_seconds = int(days) * 86400
    else:
        day_seconds = 0
    fields = value.split(':')
    if len(fields) not in (2, 3):
        raise ValueError('unexpected ps CPU time: ' + value)
    result = 0.0
    for field in fields:
        result = result * 60 + float(field)
    return day_seconds + result


def snapshot(pid):
    # lstart guards against PID reuse; never record process command lines.
    p = subprocess.run(['ps', '-p', str(pid), '-o', 'time=', '-o', 'lstart='],
                       capture_output=True, text=True, check=False)
    if p.returncode or not p.stdout.strip():
        raise RuntimeError(f'PID {pid} unavailable: {p.stderr.strip()}')
    fields = p.stdout.strip().split(maxsplit=1)
    if len(fields) != 2:
        raise RuntimeError(f'Unexpected ps output for PID {pid}')
    return cpu_seconds(fields[0]), fields[1]


def sample(args):
    targets = []
    for spec in args.pid:
        label, sep, pid = spec.partition('=')
        if not sep or not label or not pid.isdigit() or int(pid) <= 0:
            raise ValueError('--pid must be LABEL=positive_PID')
        targets.append((label, int(pid)))
    if len({p for _, p in targets}) != len(targets) or len({l for l, _ in targets}) != len(targets):
        raise ValueError('PID and label must each be unique')
    # Exclusively create, preserving existing evidence.
    with open(args.output, 'x', newline='', encoding='utf-8') as out:
        writer = csv.writer(out)
        writer.writerow(['elapsed_s', 'interval_s', 'label', 'pid', 'cpu_seconds_delta', 'cpu_percent_one_core'])
        previous = {}
        start = time.monotonic()
        for label, pid in targets:
            cpu, identity = snapshot(pid)
            previous[pid] = (cpu, identity, time.monotonic())
        for i in range(1, args.samples + 1):
            time.sleep(max(0, start + i * args.interval - time.monotonic()))
            for label, pid in targets:
                cpu, identity = snapshot(pid)
                now = time.monotonic()
                before, old_identity, then = previous[pid]
                if identity != old_identity or cpu < before:
                    raise RuntimeError(f'PID {pid} changed identity or CPU time decreased')
                interval = now - then
                writer.writerow([f'{now-start:.3f}', f'{interval:.3f}', label, pid,
                                 f'{cpu-before:.3f}', f'{100*(cpu-before)/interval:.2f}'])
                previous[pid] = (cpu, identity, now)
            out.flush()


def percentile(sorted_values, p):
    # Nearest-rank percentile, including median for consistency.
    return sorted_values[max(0, math.ceil(p * len(sorted_values)) - 1)]


def frames(args):
    values = []
    with open(args.input, newline='', encoding='utf-8-sig') as source:
        reader = csv.DictReader(source)
        if not reader.fieldnames or args.column not in reader.fieldnames:
            raise ValueError(f'missing CSV column: {args.column}')
        for row in reader:
            value = float(row[args.column])
            if not math.isfinite(value) or value <= 0:
                raise ValueError('frame intervals must be finite positive milliseconds')
            values.append(value)
    if not values:
        raise ValueError('no frame intervals')
    values.sort()
    print(f'n={len(values)} median_ms={statistics.median(values):.3f} '
          f'p95_ms={percentile(values, .95):.3f} p99_ms={percentile(values, .99):.3f} '
          f'long_frames_gt_{args.long_ms:g}ms={sum(v > args.long_ms for v in values)}')


def cpu_summary(args):
    """Summarize complete, explicit-PID sample cycles without silently dropping rows."""
    groups = {}
    with open(args.input, newline='', encoding='utf-8-sig') as source:
        for row in csv.DictReader(source):
            label, pid = row['label'], int(row['pid'])
            elapsed, interval, delta, percent = (float(row[k]) for k in
                ('elapsed_s', 'interval_s', 'cpu_seconds_delta', 'cpu_percent_one_core'))
            if not label or pid <= 0 or any(not math.isfinite(v) for v in (elapsed, interval, delta, percent)):
                raise ValueError('invalid CPU sample')
            if interval <= 0 or delta < 0 or percent < 0:
                raise ValueError('invalid CPU interval or delta')
            records = groups.setdefault(label, [])
            if records and (pid != records[-1][0] or elapsed <= records[-1][1]):
                raise ValueError('PID changed or sample time is not increasing')
            records.append((pid, elapsed, interval, delta, percent))
    if not groups or len({len(rows) for rows in groups.values()}) != 1:
        raise ValueError('missing CPU samples or incomplete sample cycles')
    totals = []
    for cycle in zip(*groups.values()):
        # The sampler queries PIDs sequentially. Reject unrelated measurement windows.
        if max(r[1] for r in cycle) - min(r[1] for r in cycle) > min(r[2] for r in cycle) / 2:
            raise ValueError('CPU sampling windows do not align')
        totals.append(sum(r[4] for r in cycle))
    result = {'cpu_unit': '100% = one core', 'processes': {}}
    for label, rows in groups.items():
        values = sorted(r[4] for r in rows)
        result['processes'][label] = dict(pid=rows[0][0], samples=len(rows),
            duration_s=sum(r[2] for r in rows),
            mean_percent=100 * sum(r[3] for r in rows) / sum(r[2] for r in rows),
            p95_percent=percentile(values, .95), peak_percent=max(values))
    result['specified_process_total'] = dict(samples=len(totals),
        mean_percent=statistics.mean(totals), p95_percent=percentile(sorted(totals), .95),
        peak_percent=max(totals))
    print(json.dumps(result, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('cpu', help='sample explicit PIDs; 100%% is one CPU core')
    p.add_argument('--pid', action='append', required=True, metavar='LABEL=PID')
    p.add_argument('--interval', type=float, default=5)
    p.add_argument('--samples', type=int, default=60)
    p.add_argument('--output', required=True, type=Path)
    p.set_defaults(func=sample)
    p = sub.add_parser('cpu-summary', help='summarize complete CPU sample cycles as JSON')
    p.add_argument('input', type=Path)
    p.set_defaults(func=cpu_summary)
    p = sub.add_parser('frames', help='summarize CSV frame intervals in milliseconds')
    p.add_argument('input', type=Path)
    p.add_argument('--column', default='frame_ms')
    p.add_argument('--long-ms', type=float, default=50)
    p.set_defaults(func=frames)
    args = parser.parse_args()
    if args.command == 'cpu' and (not math.isfinite(args.interval) or args.interval <= 0 or args.samples <= 0):
        parser.error('interval and samples must be positive')
    if args.command == 'frames' and (not math.isfinite(args.long_ms) or args.long_ms <= 0):
        parser.error('long-ms must be finite and positive')
    try:
        args.func(args)
    except (OSError, ValueError, RuntimeError) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
