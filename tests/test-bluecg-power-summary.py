import datetime as dt
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('power', Path(__file__).resolve().parents[1] / 'scripts/bluecg-power-summary.py')
power = importlib.util.module_from_spec(spec)
spec.loader.exec_module(power)


class PowerTest(unittest.TestCase):
    def block(self, second, cpu=1000):
        return f'''*** Sampled system activity (Sun Nov  1 14:25:{second:02d} 2026 +0800) (5000.00ms elapsed) ***
*** Running tasks ***
Name ID CPU ms/s User% Deadlines Wakeups Energy Impact
wine 123 500.00 80.00 1.00 0.00 2.00 0.00 75.00
CPU Power: {cpu} mW
GPU Power: 200 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): {cpu+200} mW
**** GPU usage ****
GPU Power: 999 mW
'''

    def test_window_boundaries_units_and_duplicate_gpu_sections(self):
        end = dt.datetime(2026, 11, 1, 14, 25, 20, tzinfo=dt.timezone(dt.timedelta(hours=8))).timestamp()
        text = self.block(10) + self.block(15, 2000) + self.block(20, 3000)
        result = power.summarize(text, end-11, end+1, {'game': 123, 'missing': 999})
        self.assertEqual(result['complete_samples'], 2)
        self.assertEqual(result['covered_s'], 10)
        self.assertEqual(result['power']['cpu']['mean_mw'], 2500)
        self.assertEqual(result['power']['cpu']['estimated_j'], 25)
        self.assertEqual(result['power']['gpu_processor_section']['mean_mw'], 200)
        self.assertEqual(result['processes']['game']['mean_cpu_percent_one_core'], 50)
        self.assertEqual(result['processes']['game']['mean_energy_impact'], 75)
        self.assertEqual(result['processes']['missing']['samples'], 0)

    def test_missing_power_is_not_zero(self):
        text = self.block(10).replace('CPU Power: 1000 mW\n', '')
        end = list(power.samples(text))[0]['end_epoch']
        result = power.summarize(text, end-7, end+1)
        self.assertNotIn('cpu', result['power'])
        with self.assertRaises(ValueError):
            power.summarize(text, end, end+10)


if __name__ == '__main__':
    unittest.main()
