import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('frames', Path(__file__).resolve().parents[1] / 'scripts/bluecg-present-frames.py')
frames = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frames)


class FramesTest(unittest.TestCase):
    def capture(self, failure=False):
        text = '# CYDER_DDRAW_PROFILE frequency=1000000 anchor_qpc=1000000 anchor_epoch_ns=100000000000 windows_pid=42\n'
        text += 'begin_qpc,end_qpc,thread_id,surface,left,top,width,height,primary_width,primary_height,hresult\n'
        for i, qpc in enumerate((1001000, 1011000, 1031000, 1111000)):
            text += f'{qpc-100},{qpc},7,abc,0,0,960,720,1680,945,{-1 if failure and i==1 else 0}\n'
        return text

    def test_exact_intervals_clock_anchor_and_long_frames(self):
        meta, rows = frames.load(self.capture())
        summary, intervals = frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720))
        self.assertEqual([x[0] for x in intervals], [10,20,80])
        self.assertEqual(summary['median_ms'], 20)
        self.assertEqual(summary['p95_ms'], 80)
        self.assertEqual(summary['long_frames_gt_50ms'], 1)
        self.assertAlmostEqual(summary['api_median_ms'], .1)
        self.assertEqual(rows[0]['epoch_ns'], 100001000000)

    def test_failures_and_incomplete_coverage_are_not_dropped(self):
        meta, rows = frames.load(self.capture(True))
        with self.assertRaisesRegex(ValueError, 'failed'):
            frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720))
        meta, rows = frames.load(self.capture())
        with self.assertRaisesRegex(ValueError, 'boundaries'):
            frames.extract(meta, rows, 98, 100.12, 'abc', 7, (0,0,960,720))
        with self.assertRaisesRegex(ValueError, 'nonmonotonic'):
            frames.load(self.capture() + '1110900,1111000,7,abc,0,0,960,720,1680,945,0\n')

    def test_gdi_modes_and_apis_are_not_silently_merged(self):
        text = self.capture().replace('CYDER_DDRAW_PROFILE', 'CYDER_GDI_PROFILE')
        lines = text.splitlines()
        lines[1] += ',api,src_width,src_height,stretch_mode,rop'
        for i in range(2, len(lines)):
            lines[i] += ',2,960,720,3,13369376'
        meta, rows = frames.load('\n'.join(lines)+'\n')
        summary, _ = frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720), 2)
        self.assertEqual(summary['stretch_mode'], 3)
        self.assertEqual(summary['source_dimensions'], [960,720])
        rows[-1]['stretch_mode'] = 4
        with self.assertRaisesRegex(ValueError, 'stretch mode'):
            frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720), 2)


    def test_gpu_submissions_are_separate_and_do_not_claim_a_gdi_filter(self):
        lines = self.capture().replace('CYDER_DDRAW_PROFILE', 'CYDER_GDI_PROFILE').splitlines()
        lines[1] += ',api,src_width,src_height,stretch_mode,rop'
        for i in range(2, len(lines)):
            lines[i] += ',3,961,721,3,13369376'
        meta, rows = frames.load('\n'.join(lines)+'\n')
        summary, _ = frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720), 3)
        self.assertEqual(summary['presentation_backend'], 'gpu-helper')
        self.assertIn('actual GPU sampler', summary['stretch_mode_semantics'])
        with self.assertRaisesRegex(ValueError, 'fewer than two'):
            frames.extract(meta, rows, 100, 100.12, 'abc', 7, (0,0,960,720), 2)


if __name__ == '__main__':
    unittest.main()
