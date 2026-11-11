#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('graphics', Path(__file__).resolve().parents[1] / 'scripts/graphics-signing.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cyder-signing-test-')
        self.base = Path(self.temp.name)
        self.original = self.base / 'original'
        self.original.mkdir()
        self.data = struct.pack('<8I', 0xfeedfacf, 0x01000007, 3, 6, 0, 0, 0, 0) + b'fixture'
        for name, data in [(g.NATIVE, self.data), ('x86_64-windows/d3d11.dll', b'MZ-fixture')]:
            path = self.original / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.root = self.base / 'dxmt'
        shutil.copytree(self.original, self.root)
        self.upstream = copy.deepcopy(g.UPSTREAM)
        self.upstream['fileSHA256'] = hashlib.sha256(self.data).hexdigest()
        self.patches = [patch.object(g, 'UPSTREAM', self.upstream),
                        patch.object(g, 'UPSTREAM_FILES', {n: g.digest(p) for n, p in g.files(self.original).items()})]
        for item in self.patches:
            item.start()
        self.calls = []
        self.bad_requirement = False
        self.timestamp = True
        self.invalid = False
        self.command_patch = patch.object(g, 'command', self.command)
        self.command_patch.start()
        self.decoder = self.base / 'decoder'
        self.decoder.write_text('#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write(open(sys.argv[-1],"rb").read())\n')
        self.decoder.chmod(0o755)

    def tearDown(self):
        self.command_patch.stop()
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def command(self, args):
        self.calls.append(args)
        if '--force' in args:
            self.assertIn('--timestamp', args)
            self.assertNotIn('--entitlements', args)
            path = Path(args[-1])
            path.write_bytes(path.read_bytes() + b'fixture-signature')
            return subprocess.CompletedProcess(args, 0, '')
        if '-R' in args:
            self.assertTrue(args[args.index('-R')+1].startswith('=anchor apple generic'))
            self.assertIn(g.TEAM, args[args.index('-R')+1])
            self.assertIn('identifier "local.cyder.dxmt.0.80-cyder.1.winemetal"', args[args.index('-R')+1])
            return subprocess.CompletedProcess(args, int(self.bad_requirement or self.invalid), '')
        return subprocess.CompletedProcess(args, 0, 'Timestamp=fixture-secure-time\n' if self.timestamp else 'Signature=adhoc\n')

    def prepare(self):
        return g.prepare(self.root, '0.80-cyder.1', 'Developer ID Application: Fixture')

    def test_sign_staging_only_and_record_both_hashes(self):
        before = {n: g.digest(p) for n, p in g.files(self.original).items()}
        result = self.prepare()
        self.assertEqual(before, {n: g.digest(p) for n, p in g.files(self.original).items()})
        native = next(r for r in result['files'] if r['path'] == g.NATIVE)
        self.assertEqual(native['sourceSHA256'], self.upstream['fileSHA256'])
        self.assertNotEqual(native['sourceSHA256'], native['sha256'])
        self.assertEqual(native['signature'], 'developer-id')
        g.verify_root(self.root, '0.80-cyder.1', self.original)

    def test_no_adhoc_or_same_revision_name(self):
        for version, identity in [('0.80', 'Developer ID Application: Fixture'), ('0.80-cyder.1','-')]:
            with self.assertRaises(g.Invalid):
                g.prepare(self.root, version, identity)
        self.assertEqual(self.calls, [])

    def test_modified_upstream_native_or_pe_not_signed(self):
        for name in [g.NATIVE, 'x86_64-windows/d3d11.dll']:
            path = self.root / name
            original = path.read_bytes()
            path.write_bytes(original + b'changed')
            with self.assertRaises(g.Invalid):
                self.prepare()
            path.write_bytes(original)
        self.assertEqual(self.calls, [])

    def test_unreviewed_native_or_extra_pe_not_signed(self):
        for name, data in [('other.so', self.data), ('other.dll', b'MZ-fixture')]:
            path = self.root / name
            path.write_bytes(data)
            with self.assertRaises(g.Invalid):
                self.prepare()
            path.unlink()
        self.assertEqual(self.calls, [])

    def test_wrong_team_and_missing_timestamp_fail_closed(self):
        self.prepare()
        self.bad_requirement = True
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1')
        self.bad_requirement = False
        self.timestamp = False
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1')

    def test_modified_contents_provenance_and_cached_source_rejected(self):
        self.prepare()
        meta = self.root / g.META
        original = meta.read_text()
        data = json.loads(original)
        data['files'][0]['sourceSHA256'] = '0' * 64
        meta.write_text(json.dumps(data))
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1')
        forged = json.loads(original)
        forged['signingIdentifier'] = 'local.cyder.other-component'
        meta.write_text(json.dumps(forged))
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1')
        meta.write_text(original)
        (self.original / g.NATIVE).write_bytes(b'changed source')
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1', self.original)
        (self.root / g.NATIVE).write_bytes(b'changed after signature')
        with self.assertRaises(g.Invalid):
            g.verify_root(self.root, '0.80-cyder.1')

    def test_archive_roundtrip_and_verification_never_signs(self):
        self.prepare()
        archive = self.base / 'archive.tar'
        with tarfile.open(archive, 'w') as tar:
            tar.add(self.root, arcname='dxmt')
        self.calls.clear()
        g.verify_archive(archive, str(self.decoder), '0.80-cyder.1', self.original)
        self.assertFalse(any('--force' in args for args in self.calls))
        with self.assertRaises(g.Invalid):
            g.verify_archive(archive, str(self.decoder), '0.80-cyder.2')

    def test_archive_paths_links_and_duplicates_rejected(self):
        for kind in ['traversal', 'symlink', 'duplicate']:
            archive = self.base / (kind + '.tar')
            with tarfile.open(archive, 'w') as tar:
                info = tarfile.TarInfo('dxmt/../outside' if kind == 'traversal' else 'dxmt/entry')
                if kind == 'symlink':
                    info.type = tarfile.SYMTYPE
                    info.linkname = '/tmp/outside'
                    tar.addfile(info)
                else:
                    info.size = 1
                    tar.addfile(info, io.BytesIO(b'x'))
                    if kind == 'duplicate':
                        tar.addfile(info, io.BytesIO(b'x'))
            with self.assertRaises(g.Invalid):
                g.verify_archive(archive, str(self.decoder), '0.80-cyder.1')
        self.assertFalse((self.base / 'outside').exists())

if __name__ == '__main__':
    unittest.main()
