"""Large-frame exact-output fixtures made with the pre-parallel encoder."""
import ctypes as c
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
import unittest
import numpy as np
import test_native_encoder as native
from test_frame_codec import ROOT


def fixture(name):
    y,x=np.indices((256,1024))
    pixels=np.empty((256,1024,4),dtype=np.uint8)
    gray=((x//3+y*7)%256).astype(np.uint8)
    pixels[:,:,0]=gray
    pixels[:,:,1]=gray if name!='color' else (x*7+y*11)%256
    pixels[:,:,2]=gray if name!='color' else (x*13+y*3)%256
    pixels[:,:,3]=255
    mask=np.ones(1024,dtype=np.uint8)
    if name.startswith('selected'):
        mask[:]=0;mask[1024-int(name[8:]):]=1
    return pixels,mask


class ParallelEncoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        native.NativeEncoderTests.setUpClass()
        cls.lib=native.NativeEncoderTests.lib
        cls.golden=json.loads((ROOT/'tests/fixtures/parallel-encoder-fixtures.json').read_text())

    @classmethod
    def tearDownClass(cls):native.NativeEncoderTests.tearDownClass()

    def encode(self,name,tight=False,no_mask=False):
        pixels,mask=fixture(name);expected=self.golden[name]
        capacity=expected['bytes'] if tight else 1024*1028+129
        output=c.create_string_buffer(capacity+32);c.memset(c.addressof(output)+capacity,90,32)
        size=self.lib.racer_encode_bgra(pixels.ctypes.data,pixels.nbytes,1024,256,4096,
            None if no_mask else mask.ctypes.data,0 if no_mask else len(mask),output,capacity)
        self.assertEqual(size,expected['bytes'])
        self.assertEqual(output.raw[capacity:capacity+32],b'Z'*32)
        digest=hashlib.sha256(output.raw[:size]).hexdigest()
        self.assertEqual(digest,expected['sha256'])
        return digest

    def test_dense_sparse_threshold_and_tight_buffers_match_serial_bytes(self):
        for name in self.golden:
            for tight in (False,True):
                with self.subTest(name=name,tight=tight):self.encode(name,tight)

    def test_simultaneous_encoders_do_not_share_mutable_tile_state(self):
        with ThreadPoolExecutor(max_workers=3) as pool:
            results=list(pool.map(self.encode,['text','color','selected512']*3))
        self.assertEqual(len(results),9)

    def test_full_frame_without_mask_matches_serial_bytes(self):
        for name in ('text','color'):self.encode(name,no_mask=True)

    def test_large_frame_capacity_and_invalid_input_never_overwrite_canary(self):
        pixels,mask=fixture('color');expected=self.golden['color']['bytes']
        maximum=1024*1028+129
        for capacity,size in [(0,pixels.nbytes),(expected-1,pixels.nbytes),
                              (maximum-1,pixels.nbytes),(maximum,pixels.nbytes),
                              (maximum,pixels.nbytes-1)]:
            output=c.create_string_buffer(capacity+32);c.memset(c.addressof(output)+capacity,90,32)
            result=self.lib.racer_encode_bgra(pixels.ctypes.data,size,1024,256,4096,
                mask.ctypes.data,len(mask),output,capacity)
            self.assertEqual(result,expected if capacity>=expected and size==pixels.nbytes else -1)
            self.assertEqual(output.raw[capacity:capacity+32],b'Z'*32)

    def test_worker_count_options_are_byte_exact_and_invalid_counts_rejected(self):
        f=self.lib.racer_encode_bgra_workers
        f.argtypes=self.lib.racer_encode_bgra.argtypes+[c.c_uint]
        f.restype=self.lib.racer_encode_bgra.restype
        pixels,mask=fixture('color');cap=1024*1028+129
        for workers in [1,2,4,8,0,9]:
            output=c.create_string_buffer(cap+32);c.memset(output,90,cap+32)
            n=f(pixels.ctypes.data,pixels.nbytes,1024,256,4096,mask.ctypes.data,len(mask),output,cap,workers)
            if workers in (0,9):
                self.assertEqual(n,-1);self.assertEqual(output.raw,b'Z'*(cap+32))
            else:
                self.assertEqual(n,self.golden['color']['bytes'])
                self.assertEqual(hashlib.sha256(output.raw[:n]).hexdigest(),self.golden['color']['sha256'])
                self.assertEqual(output.raw[cap:],b'Z'*32)
