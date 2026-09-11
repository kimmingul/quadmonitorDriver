"""Exercise the production C validator against the independent historical oracle.
Python is a development-only comparison tool, never an app/build dependency.
"""
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent/'support'))
import validator_cases as oracle
import jpeg_codec

class ProductionValidatorTests(oracle.NativeValidatorTests):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        path = Path(cls.temp.name) / 'validator.dylib'
        source = oracle.ROOT / 'App/Sources/CFrameEncoder/FrameValidator.c'
        subprocess.run(['clang', '-dynamiclib', '-O3', '-Wall', '-Wextra', str(source), '-o', str(path)],
                       check=True, capture_output=True)
        cls.validate = oracle.NativeValidator(path)
        cls.fixtures = cls.load_fixtures()

    def test_configuration_is_byte_identical_to_confirmed_device_quantization(self):
        function = self.validate.library.racer_configuration_quantization
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_size_t
        output = ctypes.create_string_buffer(138)
        expected = b'\xff\xdb\x00\x43\x00' + bytes(jpeg_codec.DQT_LUMA_NATURAL)
        expected += b'\xff\xdb\x00\x43\x01' + bytes(jpeg_codec.DQT_CHROMA_NATURAL)
        self.assertEqual(function(output, 138), 138)
        self.assertEqual(output.raw, expected)
        self.assertEqual(function(output, 137), 0)
