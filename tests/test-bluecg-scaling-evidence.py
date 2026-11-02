import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    'evidence', Path(__file__).resolve().parents[1] / 'scripts/bluecg-scaling-evidence.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def log(base=0x10000000, caller_delta=0x200):
    return '\n'.join([
        f'01d8:trace:loaddll:build_module Loaded L"Z:\\private-user\\bluecg.dll" at {base:08x}: native',
        '01d8:trace:loaddll:build_module Loaded L"Z:\\private-user\\DDRAW.dll" at 40000000: native',
        '01d8:err:winediag:wined3d_dll_init Using the OpenGL renderer.',
        f'01d8:Call gdi32.SetStretchBltMode(00000012,00000003) ret={base + 0x100:08x}',
        f'01d8:Call gdi32.StretchBlt(00000012,00000000,00000000,0000044c,00000317,00000020,00000000,00000000,000003c1,000002d1,00cc0020) ret={base + caller_delta:08x}',
        'Unrelated password=do-not-publish and character-private-text',
    ])


class EvidenceTests(unittest.TestCase):
    def test_aslr_independent_attribution_and_geometry(self):
        core = {'sha256': 'fixed-test-hash', 'image_size': 0x1000}
        a = MODULE.summarize(log(), core)
        b = MODULE.summarize(log(0x50000000), core)
        self.assertEqual(a, b)
        blit, = a['origin_zero_srccopy_blits_from_core']
        self.assertEqual(blit['source'], [961, 721])
        self.assertEqual(blit['destination'], [1100, 791])
        self.assertEqual(blit['stretch_mode'], 3)
        self.assertEqual(blit['mode_setter_core_offset'], '0x100')
        self.assertTrue(blit['non_integer_scale'])
        self.assertTrue(blit['non_uniform_scale'])

    def test_excludes_other_module_callers_and_private_log_text(self):
        result = MODULE.summarize(log(caller_delta=0x2000), {'image_size': 0x1000})
        self.assertEqual(result['origin_zero_srccopy_blits_from_core'], [])
        encoded = json.dumps(result)
        for private in ['private-user', 'password', 'do-not-publish', 'character-private-text']:
            self.assertNotIn(private, encoded)

    def test_ambiguous_or_missing_core_rejected(self):
        for text in ['', log() + '\n' + log(0x50000000)]:
            with self.assertRaises(ValueError):
                MODULE.summarize(text, {'image_size': 0x1000})

    def test_missing_mode_is_not_invented(self):
        text = '\n'.join(s for s in log().splitlines() if 'SetStretchBltMode(' not in s)
        result = MODULE.summarize(text, {'image_size': 0x1000})
        self.assertIsNone(result['origin_zero_srccopy_blits_from_core'][0]['stretch_mode'])


if __name__ == '__main__':
    unittest.main()
