#!/usr/bin/env python3
"""Summarize complete powermetrics intervals inside an explicit wall-clock window.

Input remains the complete private text output. Chip power estimates and process
Energy Impact are separate measurements; this tool never treats the latter as W.
"""
import argparse
import datetime as dt
import json
import math
import re
import statistics
from pathlib import Path

HEADER = re.compile(r'^\*\*\* Sampled system activity \((.*?)\) \(([\d.]+)ms elapsed\) \*\*\*$', re.M)
FIELDS = {
    'cpu': 'CPU Power', 'gpu_processor_section': 'GPU Power', 'ane': 'ANE Power',
    'combined_cpu_gpu_ane': 'Combined Power (CPU + GPU + ANE)',
}


def samples(text):
    headers = list(HEADER.finditer(text))
    for index, header in enumerate(headers):
        end = dt.datetime.strptime(header[1], '%a %b %d %H:%M:%S %Y %z').timestamp()
        seconds = float(header[2]) / 1000
        if not math.isfinite(seconds) or seconds <= 0:
            raise ValueError('invalid powermetrics sample duration')
        block = text[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(text)]
        processor = block.split('**** GPU usage ****', 1)[0]
        power = {}
        for name, field in FIELDS.items():
            matches = re.findall(r'^' + re.escape(field) + r': ([\d.]+) mW\s*$', processor, re.M)
            if len(matches) > 1:
                raise ValueError('duplicate power field: ' + field)
            if matches:
                value = float(matches[0])
                if not math.isfinite(value) or value < 0:
                    raise ValueError('invalid power value')
                power[name] = value
        tasks = {}
        for line in block.splitlines():
            # Names can contain spaces; the PID is followed by CPU ms/s and User%.
            match = re.match(r'^\s*(.*?)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+(.+?)\s*$', line)
            if not match:
                continue
            pid = int(match[2])
            tail = match[5].split()
            if len(tail) != 5:
                continue
            try:
                impact = float(tail[-1])
                cpu_ms = float(match[3])
            except ValueError:
                continue
            if all(math.isfinite(v) and v >= 0 for v in (cpu_ms, impact)):
                tasks[pid] = dict(name=match[1], cpu_percent_one_core=cpu_ms / 10,
                                  energy_impact=impact)
        yield dict(end_epoch=end, start_epoch=end - seconds, seconds=seconds,
                   power_mw=power, tasks=tasks,
                   counter_warning=('underflow' in block.lower() or 'invalid=true' in block))


def summarize(text, start, end, targets=None):
    if not all(math.isfinite(v) for v in (start, end)) or end <= start:
        raise ValueError('invalid wall-clock window')
    # Human-readable headers have only whole seconds. Keep a conservative second
    # at each boundary instead of attributing a partial edge interval to the run.
    margin = 1
    selected = [s for s in samples(text) if s['start_epoch'] >= start+margin and s['end_epoch'] <= end-margin]
    if not selected:
        raise ValueError('no complete powermetrics samples within window')
    result = dict(requested_window_s=end-start, complete_samples=len(selected),
                  covered_s=sum(s['seconds'] for s in selected),
                  counter_warning_samples=sum(s['counter_warning'] for s in selected),
                  scope='chip estimates, not whole-machine wall power or per-process watts',
                  timestamp_resolution_s=1, boundary_margin_s=margin, power={}, processes={})
    for name in FIELDS:
        values = [(s['power_mw'][name], s['seconds']) for s in selected if name in s['power_mw']]
        if not values:
            continue
        duration = sum(t for _, t in values)
        mean = sum(v*t for v, t in values) / duration
        result['power'][name] = dict(samples=len(values), covered_s=duration,
            mean_mw=mean, stdev_mw=math.sqrt(sum(t*(v-mean)**2 for v,t in values)/duration),
            p95_mw=sorted(v for v,_ in values)[math.ceil(.95*len(values))-1],
            estimated_j=sum(v*t for v,t in values)/1000)
    for label, pid in (targets or {}).items():
        values = [(s['tasks'][pid], s['seconds']) for s in selected if pid in s['tasks']]
        if not values:
            result['processes'][label] = dict(pid=pid, samples=0)
            continue
        duration = sum(t for _,t in values)
        result['processes'][label] = dict(pid=pid, samples=len(values), covered_s=duration,
            mean_cpu_percent_one_core=sum(v['cpu_percent_one_core']*t for v,t in values)/duration,
            mean_energy_impact=sum(v['energy_impact']*t for v,t in values)/duration,
            energy_impact_unit='powermetrics index; not watts or joules')
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--start-epoch', required=True, type=float)
    p.add_argument('--end-epoch', required=True, type=float)
    p.add_argument('--pid', action='append', default=[], metavar='LABEL=PID')
    a = p.parse_args()
    targets = {}
    try:
        for value in a.pid:
            label, pid = value.split('=')
            if not label or label in targets or int(pid) <= 0:
                raise ValueError('invalid or duplicate process label')
            targets[label] = int(pid)
        print(json.dumps(summarize(a.input.read_text(errors='replace'), a.start_epoch, a.end_epoch, targets), indent=2))
    except (OSError, ValueError, KeyError) as exc:
        p.error(str(exc))


if __name__ == '__main__':
    main()
