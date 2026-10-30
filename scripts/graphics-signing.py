#!/usr/bin/env python3
"""Build-time DXMT signing. Canonical source: cyder-wine-engine/scripts.
CyderBits carries the identical consumer verifier; never shipped as a runtime repair tool.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile

TEAM = '3U9565WWM2'
META = 'cyder-graphics-provenance.json'
NATIVE = 'x86_64-unix/winemetal.so'
UPSTREAM = {
    'version': 'v0.80',
    'url': 'https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz',
    'archiveSHA256': '8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d',
    'fileSHA256': '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca',
}

# Reviewed against the official archive whose digest is pinned above.
UPSTREAM_FILES = {'i386-windows/d3d10core.dll': 'c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f',
 'i386-windows/d3d11.dll': '9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d',
 'i386-windows/dxgi.dll': '7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319',
 'i386-windows/winemetal.dll': '20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3',
 'x86_64-unix/winemetal.so': '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca',
 'x86_64-windows/d3d10core.dll': '833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26',
 'x86_64-windows/d3d11.dll': '7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47',
 'x86_64-windows/dxgi.dll': 'fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544',
 'x86_64-windows/nvapi64.dll': '7c37b66a88aa1fdb08c6035a7fe738af1c1b5eea53af78c4812498d22bef8bc3',
 'x86_64-windows/nvngx.dll': '18d5847ee524ba6eeb2eee656817ddc00a45c46759a753854335a765e997e5fe',
 'x86_64-windows/winemetal.dll': '514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0'}

class Invalid(ValueError):
    pass

def need(value, message):
    if not value:
        raise Invalid(message)

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(131072), b''):
            value.update(chunk)
    return value.hexdigest()

def macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in [bytes.fromhex(s) for s in ('cffaedfe','cefaedfe','feedface','feedfacf','cafebabe','cafebabf')]

def files(root):
    need(root.is_dir() and not root.is_symlink(), 'real graphics directory required')
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        need(not path.is_symlink(), 'linked graphics input is not supported')
        need(not re.search(r'[\x00-\x1f\x7f\\]', relative), 'unsafe graphics path')
        if path.is_dir():
            continue
        need(path.is_file(), 'non-regular graphics input')
        if relative != META:
            result[relative] = path
    return result

def command(args):
    env = dict(os.environ, LC_ALL='C', LANG='C')
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=30, env=env)

def signing_identifier(version):
    return 'local.cyder.dxmt.' + version + '.winemetal'

def verify_native(path, package_version, team=TEAM):
    need(not re.search(r'[\x00-\x1f\x7f]', str(path)), 'unsafe signature path')
    requirement = '=anchor apple generic and certificate leaf[subject.OU] = "' + team + '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    requirement += ' and identifier "' + signing_identifier(package_version) + '"'
    result = command(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, str(path)])
    need(result.returncode == 0, 'Developer ID signature/Team verification failed')
    display = command(['/usr/bin/codesign', '-dv', '--verbose=4', str(path)])
    need(display.returncode == 0 and any(line.startswith('Timestamp=') and line.split('=', 1)[1].strip() not in {'', 'none', 'not set'}
                                       for line in display.stdout.splitlines()), 'secure timestamp missing')

def prepare(root, package_version, identity):
    need(re.fullmatch(r'0\.80-cyder\.[1-9][0-9]*', package_version), 'new DXMT package revision required (0.80-cyder.N)')
    need(identity.startswith('Developer ID Application: ') and identity != '-', 'release requires Developer ID Application')
    need(not (root / META).exists(), 'use original upstream input, not an already packaged tree')
    entries = files(root)
    need(NATIVE in entries, 'winemetal missing')
    native = [name for name, path in entries.items() if macho(path)]
    need(native == [NATIVE], 'unreviewed Mach-O: define its own source/signature policy first')
    need(digest(entries[NATIVE]) == UPSTREAM['fileSHA256'], 'DXMT source differs from pinned upstream bytes')
    need(set(UPSTREAM_FILES).issubset(entries) and set(entries) - set(UPSTREAM_FILES) <= {'LICENSE', 'version'}, 'upstream file set differs')
    before = {name: digest(path) for name, path in entries.items()}
    need(all(before[name] == value for name, value in UPSTREAM_FILES.items()), 'upstream payload differs from pinned archive')
    result = command(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', '--identifier', signing_identifier(package_version), str(entries[NATIVE])])
    need(result.returncode == 0, 'graphics signing failed; no ad-hoc fallback')
    verify_native(entries[NATIVE], package_version)
    rows = []
    for name, path in entries.items():
        rows.append({'path': name, 'size': path.stat().st_size, 'sourceSHA256': before[name],
                     'sha256': digest(path), 'signature': 'developer-id' if name == NATIVE else 'not-required'})
    metadata = {'schemaVersion': 1, 'component': 'dxmt', 'channel': 'release', 'packageVersion': package_version,
                'upstream': UPSTREAM, 'teamIdentifier': TEAM, 'requireTimestamp': True,
                'signingIdentifier': signing_identifier(package_version), 'files': rows}
    (root / META).write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    verify_root(root, package_version)
    return metadata

def verify_root(root, package_version, source_root=None):
    path = root / META
    need(path.is_file() and not path.is_symlink() and path.stat().st_size < 1048576, 'release provenance missing/invalid')
    meta = json.loads(path.read_text())
    need(meta.get('schemaVersion') == 1 and meta.get('component') == 'dxmt' and meta.get('channel') == 'release'
         and meta.get('packageVersion') == package_version and re.fullmatch(r'0\.80-cyder\.[1-9][0-9]*', package_version)
         and meta.get('upstream') == UPSTREAM and meta.get('teamIdentifier') == TEAM
         and meta.get('requireTimestamp') is True and meta.get('signingIdentifier') == signing_identifier(package_version), 'release provenance policy mismatch')
    entries = files(root)
    rows = meta.get('files', [])
    need(isinstance(rows, list) and len(rows) == len(entries)
         and len({r['path'] for r in rows}) == len(rows)
         and {r['path'] for r in rows} == set(entries), 'release inventory mismatch')
    native = [name for name, path in entries.items() if macho(path)]
    need(set(UPSTREAM_FILES).issubset(entries), 'upstream members missing')
    need(native == [NATIVE], 'unreviewed Mach-O in release')
    for row in rows:
        path = entries[row['path']]
        if row['path'] in UPSTREAM_FILES:
            need(row.get('sourceSHA256') == UPSTREAM_FILES[row['path']], 'upstream member digest mismatch')
        else:
            need(row['path'] in {'LICENSE', 'version'}, 'unreviewed extra file')
        need(digest(path) == row['sha256'] and path.stat().st_size == row['size'], 'release contents differ')
        if row['path'] == NATIVE:
            need(row.get('sourceSHA256') == UPSTREAM['fileSHA256'] and row.get('signature') == 'developer-id', 'native provenance mismatch')
            verify_native(path, package_version)
        else:
            need(row.get('sourceSHA256') == row['sha256'] and row.get('signature') == 'not-required', 'unexpected non-native transformation')
    if source_root:
        original = files(source_root)
        need(set(original) == set(entries) and all(digest(original[r['path']]) == r['sourceSHA256'] for r in rows),
             'cached package source changed; use a new revision')
    return meta

def verify_archive(archive, zstd, package_version, source_root=None):
    # Extract regular members ourselves, rejecting links, duplicates and traversal.
    with tempfile.TemporaryDirectory(prefix='cyder-graphics-verify-') as directory:
        base = Path(directory)
        process = subprocess.Popen([zstd, '-dc', str(archive)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            seen = set()
            total = 0
            with tarfile.open(fileobj=process.stdout, mode='r|') as tar:
                for member in tar:
                    name = member.name[2:] if member.name.startswith('./') else member.name
                    parts = PurePosixPath(name).parts
                    need(parts and parts[0] == 'dxmt' and '..' not in parts and not name.startswith('/')
                         and not re.search(r'[\x00-\x1f\x7f\\]', name), 'unsafe archive member')
                    need(name not in seen, 'duplicate archive member')
                    seen.add(name)
                    need(len(seen) <= 20000 and not member.issym() and not member.islnk(), 'linked/oversize archive inventory')
                    if member.isdir():
                        continue
                    need(member.isfile(), 'non-regular archive member')
                    total += member.size
                    need(total <= 256 * 1024 * 1024, 'graphics archive exceeds size budget')
                    target = base.joinpath(*parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open('xb') as output:
                        source = tar.extractfile(member)
                        while True:
                            chunk = source.read(131072)
                            if not chunk:
                                break
                            output.write(chunk)
            process.stdout.close()
            need(process.wait(timeout=30) == 0, 'graphics decompression failed')
            return verify_root(base / 'dxmt', package_version, source_root)
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify-archive'])
    parser.add_argument('--root', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--zstd')
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--package-version', required=True)
    parser.add_argument('--identity', default='')
    args = parser.parse_args()
    try:
        if args.action == 'prepare':
            need(args.root is not None, 'missing staging root')
            prepare(args.root, args.package_version, args.identity)
        else:
            need(args.archive is not None and args.zstd, 'missing archive/decoder')
            verify_archive(args.archive, args.zstd, args.package_version, args.source_root)
        print('PASS: DXMT release provenance, contents, Developer ID and timestamp')
    except (Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, 'Graphics release verification failed: ' + str(error) + '\n')

if __name__ == '__main__':
    main()
