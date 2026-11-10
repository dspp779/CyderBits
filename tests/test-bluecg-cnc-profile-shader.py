#!/usr/bin/env python3
"""Independent ICC reference and rejection checks for the experimental shader."""
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from PIL import Image, ImageCms

spec = importlib.util.spec_from_file_location('profile_shader', Path(__file__).resolve().parents[1]/'scripts/bluecg-cnc-profile-shader.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def gamma_profile():
    # Start with real LCMS sRGB colorants, replace its parametric TRCs with gamma 1.8.
    data = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())
    for i in range(struct.unpack_from('>I', data, 128)[0]):
        key, _, _ = struct.unpack_from('>4sII', data, 132+12*i)
        if key in (b'rTRC', b'gTRC', b'bTRC'):
            offset = len(data)
            data.extend(b'curv'+bytes(4)+struct.pack('>IH', 1, 461)+bytes(2))
            struct.pack_into('>II', data, 136+12*i, offset, 16)
    struct.pack_into('>I', data, 0, len(data))
    return bytes(data)


class ShaderTest(unittest.TestCase):
    def test_lcms_reference_and_grayscale_direction(self):
        icc = gamma_profile()
        matrix, gammas = m.coefficients(icc)
        result = m.validate(icc, matrix, gammas)
        self.assertEqual(result['colors'], 5169)
        self.assertLessEqual(result['max_channel_error'], 2)
        gray = m.convert((128,128,128), matrix, gammas)
        self.assertTrue(all(106 <= c <= 110 for c in gray))

    def test_rejects_malformed_profiles_and_unsupported_trc(self):
        for profile in (b'', bytes(132), gamma_profile()[:-1]):
            with self.assertRaises(ValueError): m.coefficients(profile)
        srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        with self.assertRaisesRegex(ValueError, 'single-gamma'): m.coefficients(srgb)
        with self.assertRaisesRegex(ValueError, 'singular'): m.inverse([[0]*3]*3)

    def test_generation_requires_profile_suffix_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp); capture = tmp/'capture.png'; output = tmp/'test-bilinear.glsl'
            Image.new('RGB',(2,2)).save(capture)
            with self.assertRaisesRegex(ValueError,'no embedded ICC'): m.generate(capture, output)
            Image.new('RGB',(2,2)).save(capture, icc_profile=gamma_profile())
            with self.assertRaisesRegex(ValueError,'suffix'): m.generate(capture,tmp/'wrong.glsl')
            result = m.generate(capture, output)
            self.assertIn(result['icc_sha256'], output.read_text())
            self.assertIn('uniform sampler2D Texture', output.read_text())
            original = output.read_bytes()
            with self.assertRaises(FileExistsError): m.generate(capture,output)
            self.assertEqual(output.read_bytes(), original)


if __name__ == '__main__': unittest.main()
