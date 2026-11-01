#!/usr/bin/env python3
"""Validate and extract DirectDraw or GDI window-update submission intervals.

Requires the opt-in engine probe. These are API submissions, not GPU completion,
scanout, input latency, or proof of a new logical animation frame.
"""
import argparse
import csv
import hashlib
import io
import json
import math
import re
import statistics
from pathlib import Path

HEADER = re.compile(r'^# CYDER_(DDRAW|GDI)_PROFILE frequency=(\d+) anchor_qpc=(\d+) anchor_epoch_ns=(\d+) windows_pid=(\d+)$')
INTEGERS = ('begin_qpc', 'end_qpc', 'thread_id', 'left', 'top', 'width', 'height',
            'primary_width', 'primary_height', 'hresult')


def load(text):
    first, _, rest = text.partition('\n')
    match = HEADER.fullmatch(first.strip())
    if not match:
        raise ValueError('missing DirectDraw probe clock header')
    kind = match[1]
    frequency, anchor, epoch_ns, pid = map(int, match.groups()[1:])
    if min(frequency, anchor, epoch_ns, pid) <= 0:
        raise ValueError('invalid clock anchor or process ID')
    meta = dict(capture_kind=kind, frequency=frequency, anchor_qpc=anchor, anchor_epoch_ns=epoch_ns, windows_pid=pid)
    rows, previous = [], {}
    try:
        for raw in csv.DictReader(io.StringIO(rest)):
            row = {key: int(raw[key]) for key in INTEGERS}
            row['surface'] = raw['surface']
            row['api'] = 0
            if kind == 'GDI':
                row.update({k: int(raw[k]) for k in ('api', 'src_width', 'src_height', 'stretch_mode', 'rop')})
                if row['api'] not in (1, 2, 3):
                    raise ValueError('unknown GDI operation')
            if not re.fullmatch(r'(?:0x)?[0-9a-fA-F]+', row['surface']):
                raise ValueError('invalid surface identity')
            if (row['begin_qpc'] <= 0 or row['end_qpc'] < row['begin_qpc'] or
                    min(row[k] for k in ('thread_id', 'width', 'height', 'primary_width', 'primary_height')) <= 0):
                raise ValueError('invalid timestamp, thread, or rectangle')
            key = (row['surface'], row['thread_id'])
            if key in previous and row['end_qpc'] <= previous[key]:
                raise ValueError('nonmonotonic timestamps within a surface/thread')
            previous[key] = row['end_qpc']
            row['epoch_ns'] = epoch_ns + (row['end_qpc'] - anchor) * 1_000_000_000 // frequency
            rows.append(row)
    except (KeyError, TypeError) as exc:
        raise ValueError('incomplete DirectDraw capture row') from exc
    if not rows:
        raise ValueError('empty capture')
    return meta, rows


def key(row):
    return tuple(row[k] for k in ('surface', 'thread_id', 'left', 'top', 'width', 'height', 'primary_width', 'primary_height', 'api')) + tuple(row.get(k) for k in ('src_width', 'src_height', 'stretch_mode', 'rop'))


def window(rows, start, end):
    if not all(math.isfinite(v) for v in (start, end)) or end <= start:
        raise ValueError('invalid measurement window')
    low, high = round(start * 1_000_000_000), round(end * 1_000_000_000)
    return [r for r in rows if low <= r['epoch_ns'] <= high]


def extract(meta, rows, start, end, surface, thread, rect, api=0):
    selected = [r for r in window(rows, start, end) if r['surface'] == surface and
                r['thread_id'] == thread and r['api'] == api and tuple(r[k] for k in ('left', 'top', 'width', 'height')) == tuple(rect)]
    if len(selected) < 2:
        raise ValueError('fewer than two matching update submissions')
    if len({key(r) for r in selected}) != 1:
        raise ValueError('target dimensions, API, source extent, ROP or stretch mode changed inside the window')
    if any(r['hresult'] < 0 for r in selected):
        raise ValueError('failed primary updates inside the selected window')
    if selected[0]['epoch_ns']/1e9 - start > 1 or end - selected[-1]['epoch_ns']/1e9 > 1:
        raise ValueError('capture does not cover both measurement-window boundaries')
    intervals = [(b['end_qpc']-a['end_qpc'])*1000/meta['frequency'] for a,b in zip(selected, selected[1:])]
    if any(v <= 0 for v in intervals):
        raise ValueError('invalid submission interval')
    values = sorted(intervals)
    api_ms = [(r['end_qpc']-r['begin_qpc'])*1000/meta['frequency'] for r in selected]
    rank = lambda p: values[math.ceil(p*len(values))-1]
    duration = sum(intervals)/1000
    scope = ('GPU final-bitmap' if api == 3 else 'GDI window blit') if meta['capture_kind'] == 'GDI' else 'DirectDraw primary update'
    summary = dict(scope=f'successful {scope} API submissions; not GPU completion or scanout',
                   capture_kind=meta['capture_kind'], api=api,
                   windows_pid=meta['windows_pid'], surface=surface, thread_id=thread, rectangle=list(rect),
                   requested_window_s=end-start, observed_interval_s=duration, submissions=len(selected),
                   intervals=len(intervals), submissions_per_s=len(intervals)/duration,
                   median_ms=statistics.median(values), p95_ms=rank(.95), p99_ms=rank(.99),
                   max_ms=max(values), long_frames_gt_50ms=sum(v>50 for v in values),
                   long_frames_gt_100ms=sum(v>100 for v in values),
                   long_frames_gt_50ms_per_min=sum(v>50 for v in values)*60/duration,
                   api_median_ms=statistics.median(api_ms), api_max_ms=max(api_ms))
    if meta['capture_kind'] == 'GDI':
        row = selected[0]
        summary['presentation_backend'] = 'gpu-helper' if api == 3 else 'gdi'
        if api == 3: summary['stretch_mode_semantics'] = 'caller DC state; actual GPU sampler must be verified separately'
        summary.update(source_dimensions=[row['src_width'], row['src_height']],
                       stretch_mode=row['stretch_mode'], rop_hex=f"0x{row['rop']:08x}")
    return summary, list(zip(intervals, selected[1:]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--start-epoch', required=True, type=float)
    p.add_argument('--end-epoch', required=True, type=float)
    p.add_argument('--list', action='store_true', help='list identities and rectangles; never guess a frame stream')
    p.add_argument('--surface')
    p.add_argument('--thread', type=int)
    p.add_argument('--api', type=int, choices=(0, 1, 2), default=0, help='0=DirectDraw, 1=BitBlt, 2=StretchBlt')
    p.add_argument('--rect', help='LEFT,TOP,WIDTH,HEIGHT')
    p.add_argument('--output', type=Path)
    a = p.parse_args()
    try:
        text = a.input.read_text()
        meta, rows = load(text)
        if a.list:
            groups = {}
            for row in window(rows, a.start_epoch, a.end_epoch):
                k = key(row)
                groups[k] = groups.get(k, 0)+1
            print(json.dumps([dict(identity=k, events=n) for k,n in groups.items()], indent=2))
            return
        if not a.surface or not a.thread or not a.rect or not a.output:
            raise ValueError('extraction requires explicit --surface, --thread, --rect and --output')
        rect = tuple(map(int, a.rect.split(',')))
        if len(rect) != 4:
            raise ValueError('--rect requires four integers')
        summary, intervals = extract(meta, rows, a.start_epoch, a.end_epoch, a.surface, a.thread, rect, a.api)
        summary['source_sha256'] = hashlib.sha256(text.encode()).hexdigest()
        with a.output.open('x', newline='') as out:
            writer = csv.writer(out)
            writer.writerow(['frame_ms', 'end_qpc', 'api_duration_ms'])
            for interval, row in intervals:
                writer.writerow([f'{interval:.6f}', row['end_qpc'], f"{(row['end_qpc']-row['begin_qpc'])*1000/meta['frequency']:.6f}"])
        with a.output.with_suffix('.summary.json').open('x') as out:
            json.dump(summary, out, indent=2)
        print(json.dumps(summary, indent=2))
    except (OSError, ValueError) as exc:
        p.error(str(exc))


if __name__ == '__main__':
    main()
