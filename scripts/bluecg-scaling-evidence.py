#!/usr/bin/env python3
"""Summarize narrow Wine GDI relay logs without publishing paths or text."""

import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import struct


LOAD = re.compile(
    r'^([0-9a-f]+):trace:loaddll:build_module Loaded L"([^"]+)" '
    r'at ([0-9a-f]+): (native|builtin)', re.I
)
CALL = re.compile(
    r'^([0-9a-f]+):Call gdi32\.(SetStretchBltMode|StretchBlt)'
    r'\(([^)]*)\) ret=([0-9a-f]+)$', re.I
)


def core_metadata(data):
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('Expected a PE32 BlueCG core DLL')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 84 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('Invalid PE header')
    if struct.unpack_from('<H', data, pe + 24)[0] != 0x10b:
        raise ValueError('Expected a PE32 optional header')
    size = struct.unpack_from('<I', data, pe + 24 + 56)[0]
    if not 0 < size < 0x80000000:
        raise ValueError('Invalid image size')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'image_size': size}


def summarize(text, core):
    lines = text.splitlines()
    loads = [m.groups() for line in lines if (m := LOAD.match(line))]
    cores = {(tid, int(base, 16)) for tid, path, base, _ in loads
             if re.split(r'[\\/]', path)[-1].lower() == 'bluecg.dll'}
    if len(cores) != 1:
        raise ValueError('Expected one unambiguous BlueCG core load')
    thread, base = next(iter(cores))
    modules = sorted({(re.split(r'[\\/]', path)[-1].lower(), kind)
                      for tid, path, _, kind in loads
                      if tid == thread and re.split(r'[\\/]', path)[-1].lower()
                      in {'ddraw.dll', 'wined3d.dll', 'opengl32.dll'}})
    states = {}
    groups = Counter()
    for line in lines:
        match = CALL.match(line)
        if not match:
            continue
        tid, api, arguments, caller = match.groups()
        values = arguments.split(',')
        if any(not re.fullmatch(r'[0-9a-f]+', value, re.I) for value in values):
            continue
        values = [int(value, 16) for value in values]
        address = int(caller, 16)
        inside = base <= address < base + core['image_size']
        if api.lower() == 'setstretchbltmode' and len(values) == 2:
            states[tid, values[0]] = (values[1], address - base if inside else None)
        elif api.lower() == 'stretchblt' and len(values) == 11 and inside:
            dc, x, y, width, height, _, sx, sy, sw, sh, rop = values
            if (x, y, sx, sy, rop) != (0, 0, 0, 0, 0x00cc0020):
                continue
            if not all(0 < v <= 16384 for v in (width, height, sw, sh)):
                continue
            mode, setter = states.get((tid, dc), (None, None))
            groups[sw, sh, width, height, mode, setter, address - base] += 1
    blits = []
    for key, count in sorted(groups.items(), key=lambda item: repr(item[0])):
        sw, sh, width, height, mode, setter, caller = key
        blits.append({
            'source': [sw, sh], 'destination': [width, height],
            'stretch_mode': mode,
            'mode_setter_core_offset': None if setter is None else hex(setter),
            'blit_caller_core_offset': hex(caller), 'observed_calls': count,
            'scale_x': str(Fraction(width, sw)),
            'scale_y': str(Fraction(height, sh)),
            'non_integer_scale': width % sw != 0 or height % sh != 0,
            'non_uniform_scale': width * sh != height * sw,
        })
    renderer = None
    for line in lines:
        if not line.startswith(thread + ':'):
            continue
        if 'Using the OpenGL renderer.' in line:
            renderer = 'gl'
        elif 'Disabling 3D support.' in line:
            renderer = 'gdi/no3d'
    return {
        'scope': 'GDI API calls, not GPU completion or scanout',
        'core': core,
        'renderer_diagnostic': renderer,
        'loaded_graphics_modules': [{'name': n, 'kind': k} for n, k in modules],
        'origin_zero_srccopy_blits_from_core': blits,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', required=True, type=Path)
    parser.add_argument('--core-dll', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = summarize(args.log.read_text(errors='replace'),
                       core_metadata(args.core_dll.read_bytes()))
    encoded = json.dumps(result, indent=2) + '\n'
    if args.output:
        with args.output.open('x') as output:
            output.write(encoded)
    else:
        print(encoded, end='')


if __name__ == '__main__':
    main()
