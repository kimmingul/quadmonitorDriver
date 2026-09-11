#!/usr/bin/env python3
"""RACERTECH USB DISP frame codec — decode + encode + byte-exact round-trip.

GROUND TRUTH (reverse-engineered from UsbDisplay binary, func.1000050d0 /
func.100004db4 / func.100004a48 / func.100005378, 2026-07-01):

  * Frame = sequence of 32x8 tiles, each `[4B LE header][entropy payload]`.
    header = 0xD0000000 | (mcuIdx<<10) | ((payloadDwords-1)<<2) | 1   (LE on wire)
    payloadLen bytes = (((word>>2)&0xFF)+1) * 4      (entropy dword-padded)
    last emitted tile: bit27 end flag; see encode_frame.py for the footer.

  * Each tile is encoded as **4:4:4**: four horizontal 8x8 positions at
    (row0col0, row0col8, row0col16, row0col24).
    For EACH position, three 8x8 blocks are emitted in order:
    Y (luma tables), Cb (chroma tables), Cr (chroma tables) => 12 blocks/MCU.

  * Standard Annex K Huffman tables. DC prediction is per-component (Y/Cb/Cr each
    keep their own predictor across the 4 positions) and RESET to 0 at MCU start.

  * writebits: MSB-first, 0xFF byte-stuffed as 0xFF 0x00. Final partial byte is
    padded with 0-BITS (vendor quirk: the bit accumulator starts zeroed, so pad
    bits below the last real bit are 0 — NOT the JPEG-standard 1-bits). Then the
    MCU is terminated with FF D9 (EOI) and the whole payload zero-padded to a
    multiple of 4 bytes (pad bytes are don't-care / uninitialised in vendor output).
"""
from pathlib import Path
import struct

# --- Standard Annex K Huffman tables ---
DC_LUMA_BITS=[0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]; DC_LUMA_VALS=list(range(12))
DC_CHROMA_BITS=[0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0]; DC_CHROMA_VALS=list(range(12))
AC_LUMA_BITS=[0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d]
AC_LUMA_VALS=[0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa]
AC_CHROMA_BITS=[0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77]
AC_CHROMA_VALS=[0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa]

# USB DQT values are NATURAL order. The historical _ZZ names below are retained
# for callers; see getQuantTable at 0x100004818 and the 2026-09-07 oracle fixtures.
DQT_LUMA_ZZ=[0x02,0x01,0x01,0x02,0x02,0x04,0x05,0x06,0x01,0x01,0x01,0x02,0x03,0x06,0x06,0x06,0x01,0x01,0x02,0x02,0x04,0x06,0x07,0x06,0x01,0x02,0x02,0x03,0x05,0x09,0x08,0x06,0x02,0x02,0x04,0x06,0x07,0x0b,0x0a,0x08,0x02,0x04,0x06,0x06,0x08,0x0a,0x0b,0x09,0x05,0x06,0x08,0x09,0x0a,0x0c,0x0c,0x0a,0x07,0x09,0x0a,0x0a,0x0b,0x0a,0x0a,0x0a]
DQT_CHROMA_ZZ=[0x02,0x02,0x02,0x05,0x0a,0x0a,0x0a,0x0a,0x02,0x02,0x03,0x07,0x0a,0x0a,0x0a,0x0a,0x02,0x03,0x06,0x0a,0x0a,0x0a,0x0a,0x0a,0x05,0x07,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a,0x0a]

ZIGZAG=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
DQT_LUMA_NATURAL = DQT_LUMA_ZZ
DQT_CHROMA_NATURAL = DQT_CHROMA_ZZ

def build_dec(bits, vals):
    table={}; code=0; k=0
    for L in range(1,17):
        for _ in range(bits[L-1]):
            table[(L,code)]=vals[k]; k+=1; code+=1
        code<<=1
    return table

def build_enc(bits, vals):
    # value -> (code, length)
    table={}; code=0; k=0
    for L in range(1,17):
        for _ in range(bits[L-1]):
            table[vals[k]]=(code,L); k+=1; code+=1
        code<<=1
    return table

DEC_DCL=build_dec(DC_LUMA_BITS,DC_LUMA_VALS); DEC_ACL=build_dec(AC_LUMA_BITS,AC_LUMA_VALS)
DEC_DCC=build_dec(DC_CHROMA_BITS,DC_CHROMA_VALS); DEC_ACC=build_dec(AC_CHROMA_BITS,AC_CHROMA_VALS)
ENC_DCL=build_enc(DC_LUMA_BITS,DC_LUMA_VALS); ENC_ACL=build_enc(AC_LUMA_BITS,AC_LUMA_VALS)
ENC_DCC=build_enc(DC_CHROMA_BITS,DC_CHROMA_VALS); ENC_ACC=build_enc(AC_CHROMA_BITS,AC_CHROMA_VALS)

# 12-block layout: (component, uses_luma_tables) for the 4 positions.
MCU_BLOCKS=[('Y',True),('Cb',False),('Cr',False)]*4

# ---------------- decode ----------------
class BitReader:
    def __init__(self,data): self.data=data; self.pos=0; self.bit=0; self.nbits=0
    def read_bit(self):
        if self.pos>=len(self.data): raise EOFError("out of bits")
        b=self.data[self.pos]; v=(b>>(7-self.bit))&1; self.bit+=1; self.nbits+=1
        if self.bit==8:
            self.bit=0; self.pos+=1
            if b==0xFF and self.pos<len(self.data) and self.data[self.pos]==0x00:
                self.pos+=1
        return v
    def huff(self,table):
        code=0
        for L in range(1,17):
            code=(code<<1)|self.read_bit()
            if (L,code) in table: return table[(L,code)]
        raise ValueError("bad huffman code")
    def recv_extend(self,s):
        if s==0: return 0
        v=0
        for _ in range(s): v=(v<<1)|self.read_bit()
        if v<(1<<(s-1)): v+=(-1<<s)+1
        return v

def decode_block(br,dcT,acT,pred):
    s=br.huff(dcT); diff=br.recv_extend(s); dc=pred+diff
    coeffs=[0]*64; coeffs[0]=dc; k=1
    while k<64:
        rs=br.huff(acT); r=rs>>4; s=rs&0xF
        if s==0:
            if r==15: k+=16; continue
            break
        k+=r
        if k>=64: raise ValueError("AC run exceeds block")
        coeffs[ZIGZAG[k]]=br.recv_extend(s); k+=1
    return dc,coeffs

def decode_mcu(payload):
    """Return list of 12 blocks, each a length-64 list of quantized coeffs (natural order)."""
    br=BitReader(payload); preds={'Y':0,'Cb':0,'Cr':0}; blocks=[]
    for comp,luma in MCU_BLOCKS:
        dcT,acT=(DEC_DCL,DEC_ACL) if luma else (DEC_DCC,DEC_ACC)
        dc,coeffs=decode_block(br,dcT,acT,preds[comp]); preds[comp]=dc
        blocks.append(coeffs)
    end_byte=br.pos+(1 if br.bit else 0)
    if payload[end_byte:end_byte+2] != b"\xff\xd9":
        raise ValueError("missing EOI after tile entropy")
    return blocks,end_byte

# ---------------- encode ----------------
class BitWriter:
    """MSB-first bit writer with JPEG 0xFF byte-stuffing (matches func.100004a48)."""
    def __init__(self): self.out=bytearray(); self.acc=0; self.nbits=0
    def put(self,code,length):
        self.acc=(self.acc<<length)|(code&((1<<length)-1)); self.nbits+=length
        while self.nbits>=8:
            self.nbits-=8; byte=(self.acc>>self.nbits)&0xFF
            self.out.append(byte)
            if byte==0xFF: self.out.append(0x00)  # byte-stuff
    def flush_zero(self):
        # pad final partial byte with 0-bits (vendor quirk), then no stuffing needed
        if self.nbits>0:
            byte=(self.acc<<(8-self.nbits))&0xFF
            self.out.append(byte)
            if byte==0xFF: self.out.append(0x00)
            self.nbits=0; self.acc=0

def _mag(v):
    # returns (size, mantissa_bits) for signed value v (JPEG "extend")
    if v==0: return 0,0
    a=abs(v); s=a.bit_length()
    if v<0: v=v-1  # ones' complement for negatives
    return s,(v&((1<<s)-1))

def encode_block(bw,coeffs,dcEnc,acEnc,pred):
    coeffs = [coeffs[k] for k in ZIGZAG]
    dc=coeffs[0]; diff=dc-pred
    s,m=_mag(diff)
    code,L=dcEnc[s]; bw.put(code,L)
    if s: bw.put(m,s)
    # AC
    k=1; run=0
    # find last nonzero
    last=0
    for i in range(63,0,-1):
        if coeffs[i]!=0: last=i; break
    while k<=last:
        if coeffs[k]==0:
            run+=1; k+=1; continue
        while run>15:
            code,L=acEnc[0xF0]; bw.put(code,L); run-=16  # ZRL
        s,m=_mag(coeffs[k])
        code,L=acEnc[(run<<4)|s]; bw.put(code,L); bw.put(m,s)
        run=0; k+=1
    if last<63:  # EOB
        code,L=acEnc[0x00]; bw.put(code,L)
    return dc

def encode_mcu(blocks, dword_pad=True, pad_byte=0x00):
    """blocks = 12 lists of 64 coeffs (natural order). Returns entropy payload
    bytes: <entropy> FF D9 [<dword pad>]."""
    bw=BitWriter(); preds={'Y':0,'Cb':0,'Cr':0}
    for (comp,luma),coeffs in zip(MCU_BLOCKS,blocks):
        dcEnc,acEnc=(ENC_DCL,ENC_ACL) if luma else (ENC_DCC,ENC_ACC)
        dc=encode_block(bw,coeffs,dcEnc,acEnc,preds[comp]); preds[comp]=dc
    bw.flush_zero()
    payload=bytearray(bw.out); payload+=b"\xFF\xD9"
    if dword_pad:
        while len(payload)%4!=0: payload.append(pad_byte)
    return bytes(payload)

def make_header(mcu_idx,payload_len,end=False):
    if not 0 <= mcu_idx <= 65535:
        raise ValueError("tile index must fit the 16-bit header field")
    if not 4 <= payload_len <= 1024 or payload_len % 4:
        raise ValueError("payload must be 4..1024 bytes, in whole dwords")
    dwords=payload_len//4
    word=(mcu_idx<<10)|(((dwords-1)&0xFF)<<2)|1
    word|=0xD8000000 if end else 0xD0000000
    return struct.pack("<I",word)

# ---------------- round-trip self-test ----------------
if __name__=="__main__":
    import sys
    path=sys.argv[1] if len(sys.argv)>1 else str(Path(__file__).resolve().parents[1]/"fixtures/coldframe_000.bin")
    N=int(sys.argv[2]) if len(sys.argv)>2 else 9000
    data=open(path,"rb").read()
    off=0; ok=0; mismatch=0; failed=0; checked=0
    for m in range(N):
        word=struct.unpack_from("<I",data,off)[0]
        if word & 0xf4000003 != 0xd0000001: break
        plen=(((word>>2)&0xFF)+1)*4
        payload=data[off+4:off+4+plen]
        try:
            blocks,end_byte=decode_mcu(payload)
            # re-encode entropy (up to FF D9) and compare against vendor entropy up to its FF D9
            reenc=encode_mcu(blocks,dword_pad=False)  # <entropy> FF D9
            # vendor entropy up to and including FF D9:
            # end_byte points just past entropy; vendor has FF D9 right after (byte-aligned)
            vend=payload[:end_byte+2]
            checked+=1
            if reenc==vend: ok+=1
            else:
                mismatch+=1
                if mismatch<=3:
                    print(f"  MISMATCH MCU{m}: len re={len(reenc)} vend={len(vend)}")
                    print(f"    re  ={reenc.hex()}")
                    print(f"    vend={vend.hex()}")
        except Exception as e:
            failed+=1
            if failed<=3: print(f"  DECODE FAIL MCU{m}: {e}")
        off+=4+plen
        if word & (1 << 27): break
    print(f"checked={checked} byte_exact={ok} mismatch={mismatch} decode_fail={failed}")
    sys.exit(0 if checked and not mismatch and not failed else 1)
