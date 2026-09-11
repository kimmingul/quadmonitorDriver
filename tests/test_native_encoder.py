"""Compile the production C codec; compare against archived binary and libjpeg."""
import ctypes as c
from pathlib import Path
import subprocess
import tempfile
import unittest
import numpy as np
from test_frame_codec import ROOT, FIXTURE, pattern, blocks, decode_image
from frame_protocol import validate_frame

class NativeEncoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        source = ROOT / 'App/Sources/CFrameEncoder'
        lib = Path(cls.temp.name) / 'encoder.dylib'
        subprocess.run(['clang', '-dynamiclib', '-O3', '-Wall', '-Wextra',
                        '-I'+str(source/'include'), str(source/'FrameEncoder.c'),
                        '-o', str(lib)], check=True, capture_output=True)
        cls.lib = c.CDLL(str(lib))
        cls.lib.racer_frame_capacity.argtypes = [c.c_uint,c.c_uint]
        cls.lib.racer_frame_capacity.restype = c.c_size_t
        cls.lib.racer_encode_bgra.argtypes = [c.c_void_p,c.c_size_t,c.c_uint,c.c_uint,
            c.c_size_t,c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t]
        cls.lib.racer_encode_bgra.restype = c.c_ssize_t
        cls.lib.racer_mark_changed_tiles.argtypes = [c.c_void_p,c.c_void_p,c.c_size_t,
            c.c_uint,c.c_uint,c.c_void_p,c.c_size_t]
        cls.lib.racer_mark_changed_tiles.restype = c.c_int

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def encode(self, rgb, mask=None, padding=0):
        h,w = rgb.shape[:2]
        pixels = np.full((h,w+padding,4), 255, np.uint8)
        pixels[:,:w,:3] = rgb[:,:,::-1]
        cap = self.lib.racer_frame_capacity(w,h)
        self.assertGreater(cap, 0)
        out = c.create_string_buffer(cap)
        select = None if mask is None else (c.c_uint8*len(mask))(*mask)
        count = self.lib.racer_encode_bgra(pixels.ctypes.data,pixels.nbytes,w,h,
            pixels.strides[0],select,0 if mask is None else len(mask),out,cap)
        self.assertGreaterEqual(count, 0)
        return out.raw[:count]

    def test_geometry_entropy_matches_original_binary(self):
        data = self.encode(pattern('geometry'))
        reference = bytes.fromhex(FIXTURE['cases']['geometry']['frame_hex'])
        entropy = lambda d: [p[:p.index(b'\xff\xd9')+2] for _,p,_ in blocks(d)]
        self.assertEqual(entropy(data), entropy(reference))

    def test_changes_preserve_both_history_masks_and_old_cursor_location(self):
        current = np.zeros((16,64,4),dtype=np.uint8)
        previous = current.copy()
        previous[0,0,0] = 255  # Old cursor, tile 0 must be erased.
        current[15,63,3] = 255  # New cursor, final byte of tile 3 (including alpha).
        mask = (c.c_uint8*4)(0,1,0,0)  # Tile 1 was changed against the other history.
        self.assertEqual(self.lib.racer_mark_changed_tiles(current.ctypes.data,previous.ctypes.data,
            current.nbytes,64,16,mask,4),0)
        self.assertEqual(list(mask),[1,1,0,1])

    def test_tile_selection_matches_independent_pixel_oracle(self):
        rng = np.random.default_rng(20260909)
        current = rng.integers(0,256,(24,96,4),dtype=np.uint8)
        for count in (0,1,2,20,100):
            previous = current.copy()
            for _ in range(count):
                previous[int(rng.integers(24)),int(rng.integers(96)),int(rng.integers(4))] ^= 255
            expected = [int(np.any(current[y:y+8,x:x+32] != previous[y:y+8,x:x+32]))
                        for y in range(0,24,8) for x in range(0,96,32)]
            mask = (c.c_uint8*9)()
            self.assertEqual(self.lib.racer_mark_changed_tiles(current.ctypes.data,previous.ctypes.data,
                current.nbytes,96,24,mask,9),0)
            self.assertEqual(list(mask),expected)

    def test_invalid_comparison_keeps_mask_canary(self):
        pixels = c.create_string_buffer(1024)
        for w,h,size,mask_size in [(31,8,1024,1),(32,7,1024,1),(32,8,1023,1),(32,8,1024,0)]:
            mask = c.create_string_buffer(b'UNCHANGED')
            self.assertEqual(self.lib.racer_mark_changed_tiles(pixels,pixels,size,w,h,mask,mask_size),-1)
            self.assertEqual(mask.value,b'UNCHANGED')

    def test_ac_pixels_decode_independently_with_padded_stride(self):
        rgb = pattern('ac_pattern')
        data = self.encode(rgb,padding=7)
        self.assertEqual(validate_frame(data,64,16,keyframe=True),list(range(4)))
        self.assertLess(np.abs(decode_image(data,64,16).astype(int)-rgb).mean(),3)

    def test_selected_tile_end_marker_and_empty_selection(self):
        rgb = pattern('geometry')
        data = self.encode(rgb,[0,1,0,0])
        self.assertEqual(validate_frame(data,64,16),[1])
        self.assertEqual(self.encode(rgb,[0,0,0,0]),b'')

    def test_aligned_body_requires_full_footer(self):
        data = self.encode(pattern('aligned_footer'))
        end = list(blocks(data))[-1][2]
        self.assertEqual(end%128,0)
        self.assertEqual(data[end:],b'\xff\xd9\xff\xff'*32+b'\0')

    def test_noise_entropy_and_pixel_reconstruction(self):
        rgb = np.random.default_rng(42).integers(0,256,(16,64,3),dtype=np.uint8)
        data = self.encode(rgb)
        validate_frame(data,64,16,keyframe=True)
        self.assertLess(np.abs(decode_image(data,64,16).astype(int)-rgb).mean(),4)

    def test_invalid_sizes_and_capacity_never_overwrite_canary(self):
        pixels = c.create_string_buffer(32*8*4)
        for w,h,stride,n,mask,ms,cap in [
            (31,8,128,1024,None,0,16),(32,7,128,1024,None,0,16),
            (32,8,127,1024,None,0,16),(32,8,128,1023,None,0,16),
            (32,8,128,1024,None,0,1),
            (32,8,128,1024,(c.c_uint8*1)(1),0,16)]:
            out = c.create_string_buffer(b'X'*64)
            with self.subTest(w=w,h=h,stride=stride,n=n,cap=cap):
                result = self.lib.racer_encode_bgra(pixels,n,w,h,stride,mask,ms,out,cap)
                self.assertEqual(result,-1)
                self.assertEqual(out.raw[cap:64],b'X'*(64-cap))
        self.assertEqual(self.lib.racer_frame_capacity(0,8),0)
        self.assertEqual(self.lib.racer_frame_capacity(0xffffffff,0xffffffff),0)

if __name__ == '__main__': unittest.main()
