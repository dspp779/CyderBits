import importlib.util
import io
import contextlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('bench', Path(__file__).resolve().parents[1] / 'scripts/bluecg-benchmark.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class BenchmarkTest(unittest.TestCase):
    def test_cpu_summary_and_incomplete_cycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'cpu.csv'
            header = 'elapsed_s,interval_s,label,pid,cpu_seconds_delta,cpu_percent_one_core\n'
            rows = ('5,5,game,1,5,100\n5.01,5,wineserver,2,0.05,1\n'
                    '10,5,game,1,10,200\n10.01,5,wineserver,2,0.1,2\n')
            path.write_text(header + rows)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                bench.cpu_summary(SimpleNamespace(input=path))
            result = json.loads(output.getvalue())
            self.assertEqual(result['processes']['game']['mean_percent'], 150)
            self.assertEqual(result['specified_process_total']['mean_percent'], 151.5)
            self.assertEqual(result['specified_process_total']['p95_percent'], 202)
            path.write_text(header + rows + '15,5,game,1,1,20\n')
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                bench.cpu_summary(SimpleNamespace(input=path))

    def test_cpu_time(self):
        self.assertEqual(bench.cpu_seconds('2:03.50'), 123.5)
        self.assertEqual(bench.cpu_seconds('1-02:03:04'), 93784)

    def test_frames_and_invalid_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'frames.csv'
            path.write_text('frame_ms\n10\n20\n30\n100\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                bench.frames(SimpleNamespace(input=path, column='frame_ms', long_ms=50))
            self.assertEqual(output.getvalue().strip(), 'n=4 median_ms=25.000 p95_ms=100.000 p99_ms=100.000 long_frames_gt_50ms=1')
            path.write_text('frame_ms\nnan\n')
            with self.assertRaises(ValueError):
                bench.frames(SimpleNamespace(input=path, column='frame_ms', long_ms=50))

    def test_cpu_deltas_and_pid_reuse(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(pid=['game=42'], output=Path(tmp) / 'cpu.csv', interval=1, samples=1)
            with patch.object(bench, 'snapshot', side_effect=[(10, 'start'), (12, 'start')]), \
                 patch.object(bench.time, 'monotonic', side_effect=[0, 0, 0, 2]), \
                 patch.object(bench.time, 'sleep'):
                bench.sample(args)
            self.assertIn('game,42,2.000,100.00', args.output.read_text())
            args.output = Path(tmp) / 'reuse.csv'
            with patch.object(bench, 'snapshot', side_effect=[(10, 'old'), (12, 'new')]), \
                 patch.object(bench.time, 'monotonic', side_effect=[0, 0, 0, 2]), \
                 patch.object(bench.time, 'sleep'):
                with self.assertRaises(RuntimeError):
                    bench.sample(args)


if __name__ == '__main__':
    unittest.main()
