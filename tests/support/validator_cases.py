"""Differential validation against the unchanged Python decoder and vendor fixtures."""
import ctypes
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/support'))
from frame_protocol import validate_frame as reference
from native_validator import NativeValidator,SOURCES

class NativeValidatorTests(unittest.TestCase):
    @staticmethod
    def load_fixtures():
        cases=json.loads((ROOT/'tests/fixtures/vendor_fixtures.json').read_text())['cases']
        # encodeFrame output excludes the extra transport byte. These tests
        # validate USB frames, including that byte, at the actual fixture size.
        for row in cases.values():
            data=bytes.fromhex(row['frame_hex'])
            assert len(data)%128==0
            row['frame_hex']=(data+b'\0').hex()
        return cases

    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        path=Path(cls.temp.name)/'validator.dylib'
        subprocess.run(['clang','-dynamiclib','-O3','-Wall','-Wextra',str(SOURCES[0]),'-o',str(path)],check=True,capture_output=True)
        cls.validate=NativeValidator(path)
        cls.fixtures=cls.load_fixtures()

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def assert_same(self,data,w=64,h=16,keyframe=False):
        try:expected=reference(data,w,h,keyframe)
        except (ValueError,EOFError):
            with self.assertRaises(ValueError):self.validate(data,w,h,keyframe)
        else:self.assertEqual(self.validate(data,w,h,keyframe),expected)

    def test_all_vendor_fixtures_and_every_truncation(self):
        for name,row in self.fixtures.items():
            data=bytes.fromhex(row['frame_hex'])
            with self.subTest(name=name):
                w,h=row['width'],row['height']
                self.assertEqual(reference(data,w,h,True),list(range((w//32)*(h//8))))
                self.assert_same(data,w,h,keyframe=True)
                # Truncation cannot become valid by bypassing entropy or footer.
                for end in range(len(data)):
                    with self.assertRaises(ValueError):self.validate(data[:end],w,h,True)

    def test_deterministic_corruption_parity(self):
        rng=random.Random(20260907)
        for row in self.fixtures.values():
            original=bytes.fromhex(row['frame_hex'])
            for _ in range(250):
                data=bytearray(original)
                for _ in range(rng.randrange(1,5)):
                    i=rng.randrange(len(data));data[i]^=1<<rng.randrange(8)
                self.assert_same(bytes(data),row['width'],row['height'],keyframe=True)

    def test_actual_complete_vendor_frame(self):
        data=(ROOT/'tests/fixtures/coldframe_000.bin').read_bytes()
        self.assert_same(data,1920,1200,True)

    def test_every_byte_mutation_matches_oracle_across_fast_prefix_and_stuffing(self):
        # Exercise code boundaries, short tails and FF/00 transitions using
        # an independent decoder, including mutations that remain valid.
        for name in ('geometry','ac_pattern','aligned_footer'):
            row=self.fixtures[name]
            original=bytes.fromhex(row['frame_hex'])
            for offset in range(len(original)):
                for value in (0,255,original[offset]^0x80):
                    data=bytearray(original);data[offset]=value
                    self.assert_same(bytes(data),row['width'],row['height'],keyframe=True)

    def test_partial_frames_cannot_be_initial_keyframes(self):
        data=bytes.fromhex(self.fixtures['geometry']['frame_hex'])
        self.assert_same(data,128,16,False)
        with self.assertRaises(ValueError):self.validate(data,128,16,True)

    def test_invalid_capacity_never_writes_output(self):
        data=bytes.fromhex(self.fixtures['geometry']['frame_hex'])
        for capacity in (0,1,3):
            output=ctypes.create_string_buffer(b'X'*32)
            rc=self.validate.function(data,len(data),64,16,1,output,capacity)
            self.assertEqual(rc,-1);self.assertEqual(output.raw[:32],b'X'*32)
        for w,h in ((0,16),(63,16),(64,15),(0xffffffff,0xffffffff)):
            with self.assertRaises(ValueError):self.validate(data,w,h)
