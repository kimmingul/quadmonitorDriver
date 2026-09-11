"""Regression checks grounded in archived vendor machine code and libjpeg.

uv run --no-project --with numpy --with pillow python -m unittest discover -s tests -v
The oracle fixtures are generated offline with vendor_oracle.py; Unicorn is not
needed to run these tests. Pillow/libjpeg independently decodes entropy pixels.
"""
from pathlib import Path
from unittest.mock import patch
import hashlib
import io
import json
import struct
import sys
import unittest
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
AUDIT=ROOT/'tests/fixtures'
sys.path[:0]=[str(ROOT/'tests/support')]
import jpeg_codec as jc
import encode_frame as ef
from oracle_patterns import pattern

FIXTURE=json.loads((AUDIT/'vendor_fixtures.json').read_text())
DQT=bytes.fromhex(FIXTURE['dqt_hex'])
# Read natural-order values from the ORIGINAL encoder, not from our constants.
QN=[list(DQT[5:69]),list(DQT[74:138])]

def marker(code,data):
    return bytes([255,code])+struct.pack('>H',len(data)+2)+data

def decode_tile(payload):
    # Convert the vendor's natural-order USB tables to standard JPEG DQT order.
    q=marker(0xdb,bytes([0]+[QN[0][k] for k in jc.ZIGZAG]+[1]+[QN[1][k] for k in jc.ZIGZAG]))
    tables=b''
    for flag,bits,vals in [(0,jc.DC_LUMA_BITS,jc.DC_LUMA_VALS),(16,jc.AC_LUMA_BITS,jc.AC_LUMA_VALS),
                           (1,jc.DC_CHROMA_BITS,jc.DC_CHROMA_VALS),(17,jc.AC_CHROMA_BITS,jc.AC_CHROMA_VALS)]:
        tables+=marker(0xc4,bytes([flag]+bits+vals))
    sof=marker(0xc0,bytes([8])+struct.pack('>HH',8,32)+bytes([3,1,17,0,2,17,1,3,17,1]))
    sos=marker(0xda,bytes([3,1,0,2,17,3,17,0,63,0]))
    return np.asarray(Image.open(io.BytesIO(b'\xff\xd8'+q+tables+sof+sos+payload)).convert('RGB'))

def blocks(data):
    off=0
    while True:
        word,=struct.unpack_from('<I',data,off)
        if word&0xf4000003 !=0xd0000001:raise ValueError(f'bad header at {off}')
        length=(((word>>2)&255)+1)*4
        if off+4+length>len(data):raise ValueError('truncated block')
        yield (word>>10)&65535,data[off+4:off+4+length],off+4+length
        off+=4+length
        if word&(1<<27):return

def decode_image(data,width,height):
    rgb=np.zeros((height,width,3),np.uint8)
    for index,payload,end in blocks(data):
        row,col=divmod(index,width//32)
        rgb[row*8:row*8+8,col*32:col*32+32]=decode_tile(payload)
    return rgb

def encode_small(rgb):
    h,w=rgb.shape[:2]
    with patch.multiple(ef,W=w,H=h,MCUS_X=w//ef.MCU_W,MCUS_Y=h//ef.MCU_H):
        return ef.encode_frame(rgb)

class FrameCodecTests(unittest.TestCase):
    def test_oracle_fixtures_reconstruct_known_inputs_with_independent_libjpeg(self):
        for name,case in FIXTURE['cases'].items():
            with self.subTest(name=name):
                rgb=pattern(name)
                self.assertEqual(hashlib.sha256(rgb.tobytes()).hexdigest(),case['rgb_sha256'])
                result=decode_image(bytes.fromhex(case['frame_hex']),rgb.shape[1],rgb.shape[0])
                self.assertLess(np.abs(result.astype(int)-rgb).mean(),3.0)

    def test_generated_tile_positions_match_original_encoder(self):
        rgb=pattern('geometry')
        actual=encode_small(rgb)
        expected=bytes.fromhex(FIXTURE['cases']['geometry']['frame_hex'])
        # Compare entropy, excluding uninitialized vendor per-block alignment bytes.
        actual_entropy=[p[:p.index(b'\xff\xd9')+2] for _,p,_ in blocks(actual)]
        expected_entropy=[p[:p.index(b'\xff\xd9')+2] for _,p,_ in blocks(expected)]
        self.assertEqual(actual_entropy,expected_entropy)

    def test_ac_pixels_reconstruct_correctly_in_independent_decoder(self):
        rgb=pattern('ac_pattern')
        result=decode_image(encode_small(rgb),rgb.shape[1],rgb.shape[0])
        self.assertLess(np.abs(result.astype(int)-rgb).mean(),3.0)

    def test_aligned_frame_still_has_128_footer_bytes(self):
        actual=encode_small(pattern('aligned_footer'))
        body_end=list(blocks(actual))[-1][2]
        self.assertEqual(body_end%128,0)
        self.assertEqual(actual[body_end:],b'\xff\xd9\xff\xff'*32+b'\0')

    def test_quantization_uses_original_natural_order(self):
        self.assertEqual(ef.QL.flatten().tolist(),QN[0])
        self.assertEqual(ef.QC.flatten().tolist(),QN[1])

    def test_header_rejects_unrepresentable_payload_lengths(self):
        for length in (0,3,1028):
            with self.subTest(length=length),self.assertRaises(ValueError):jc.make_header(0,length)

    def test_header_rejects_out_of_range_tile_positions(self):
        for index in (-1,65536):
            with self.subTest(index=index),self.assertRaises(ValueError):jc.make_header(index,16)

    def test_entropy_decoder_requires_actual_eoi(self):
        payload=jc.encode_mcu([[0]*64 for _ in range(12)],dword_pad=False)
        with self.assertRaises(ValueError):jc.decode_mcu(payload[:-2]+b'\0\0')

if __name__=='__main__':unittest.main()
