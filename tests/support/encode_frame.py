#!/usr/bin/env python3
"""Pixel front-end for the RACERTECH USB DISP encoder.

RGB image (1920x1200) -> YCbCr 4:4:4 + level shift -> 8x8 fDCT -> quantize with
the vendor DQT -> zigzag -> jpeg_codec.encode_mcu (12-block interleaved 4:4:4) ->
0xD0 container. Produces a full 9000-MCU frame identical in structure to the
vendor keyframes (verified byte-exact at the entropy layer by jpeg_codec.py).

The pixel path is NOT byte-exact vs the vendor (fDCT rounding differs) but is
verified with an independent JPEG decoder. Physical display output still needs
visual verification; transport success alone does not establish correct pixels.

Usage:
  encode_frame.py bars   out.bin        # SMPTE-ish colour bars test frame
  encode_frame.py solid R G B out.bin   # solid colour test frame
  encode_frame.py selftest              # encode->decode round-trip sanity
"""
import sys, struct
import numpy as np
import jpeg_codec as jc

W, H = 1920, 1200
MCU_W, MCU_H = 32, 8
MCUS_X, MCUS_Y = W // MCU_W, H // MCU_H   # 60 x 150 = 9000

# --- orthonormal 8x8 DCT basis (matches JPEG Annex A normalisation) ---
_x = np.arange(8)
_D = np.zeros((8, 8))
for u in range(8):
    c = (1/np.sqrt(2)) if u == 0 else 1.0
    _D[u] = 0.5 * c * np.cos((2*_x + 1) * u * np.pi / 16)

def fdct8(block):          # block: 8x8 float (already level-shifted)
    return _D @ block @ _D.T

def idct8(coeffs):
    return _D.T @ coeffs @ _D

# The USB DQT wrapper carries natural-order values, unlike a JPEG file's DQT.
QL = np.array(jc.DQT_LUMA_NATURAL, dtype=np.float64).reshape(8, 8)
QC = np.array(jc.DQT_CHROMA_NATURAL, dtype=np.float64).reshape(8, 8)

# --- colour transform (JFIF full-range) ---
def rgb_to_ycbcr(rgb):     # rgb float array [...,3] in 0..255 -> y,cb,cr planes
    R, G, B = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    Y  = 0.299*R + 0.587*G + 0.114*B
    Cb = 128 - 0.168736*R - 0.331264*G + 0.5*B
    Cr = 128 + 0.5*R - 0.418688*G - 0.081312*B
    return Y, Cb, Cr

def ycbcr_to_rgb(Y, Cb, Cr):
    R = Y + 1.402*(Cr-128)
    G = Y - 0.344136*(Cb-128) - 0.714136*(Cr-128)
    B = Y + 1.772*(Cb-128)
    return np.clip(np.stack([R, G, B], -1), 0, 255).astype(np.uint8)

# zigzag map: natural index (0..63) -> coeff list already natural for encode_mcu
def quant_block(pixels8, Q):
    coeffs = fdct8(pixels8 - 128.0)
    q = np.round(coeffs / Q).astype(np.int32)
    return q.reshape(64).tolist()   # natural order (encode_mcu handles zigzag scan)

def encode_frame(rgb):
    """rgb: HxWx3 uint8. Returns full frame bytes (0xD0 container, 9000 MCU)."""
    Y, Cb, Cr = rgb_to_ycbcr(rgb.astype(np.float64))
    out = bytearray()
    # Four horizontal 8x8 positions within each 32x8 tile.
    POS = [(0, 0), (0, 8), (0, 16), (0, 24)]
    for my in range(MCUS_Y):
        for mx in range(MCUS_X):
            y0, x0 = my*MCU_H, mx*MCU_W
            blocks = []
            for (dy, dx) in POS:
                ys, xs = y0+dy, x0+dx
                yb  = Y [ys:ys+8, xs:xs+8]
                cbb = Cb[ys:ys+8, xs:xs+8]
                crb = Cr[ys:ys+8, xs:xs+8]
                blocks.append(quant_block(yb,  QL))   # Y  luma
                blocks.append(quant_block(cbb, QC))   # Cb chroma
                blocks.append(quant_block(crb, QC))   # Cr chroma
            idx = my*MCUS_X + mx
            last = (idx == MCUS_X*MCUS_Y - 1)
            payload = jc.encode_mcu(blocks, dword_pad=True)
            out += jc.make_header(idx, len(payload), end=last)
            out += payload
    # Original encodeFrame at 0x100002830 uses a do-while: write at least one
    # ff d9 ff ff dword, stopping at the NEXT 128-byte boundary (4..128 bytes).
    # Confirmed against 300 accepted captured frames, including 8 aligned bodies.
    # WritePipe adds one extra byte; captures show it need not be zero. Choose 0.
    assert len(out) % 4 == 0, "block payloads must be dword-aligned before footer"
    fill_len = 128 - (len(out) % 128)
    out += b"\xff\xd9\xff\xff" * (fill_len // 4)
    out.append(0x00)
    return bytes(out)

# --- decode for verification (mirror of encoder, using jpeg_codec.decode_mcu) ---
def decode_frame(data):
    rgb = np.zeros((H, W, 3), np.uint8)
    Yp = np.zeros((H, W)); Cbp = np.zeros((H, W)); Crp = np.zeros((H, W))
    POS = [(0, 0), (0, 8), (0, 16), (0, 24)]
    off = 0
    for idx in range(MCUS_X*MCUS_Y):
        word = struct.unpack_from("<I", data, off)[0]
        plen = (((word >> 2) & 0xFF) + 1) * 4
        payload = data[off+4:off+4+plen]
        blocks, _ = jc.decode_mcu(payload)
        my, mx = divmod(idx, MCUS_X)
        y0, x0 = my*MCU_H, mx*MCU_W
        for p, (dy, dx) in enumerate(POS):
            yb  = idct8(np.array(blocks[p*3+0]).reshape(8, 8) * QL) + 128
            cbb = idct8(np.array(blocks[p*3+1]).reshape(8, 8) * QC) + 128
            crb = idct8(np.array(blocks[p*3+2]).reshape(8, 8) * QC) + 128
            ys, xs = y0+dy, x0+dx
            Yp[ys:ys+8, xs:xs+8] = yb
            Cbp[ys:ys+8, xs:xs+8] = cbb
            Crp[ys:ys+8, xs:xs+8] = crb
        off += 4 + plen
    return ycbcr_to_rgb(Yp, Cbp, Crp)

def make_bars():
    rgb = np.zeros((H, W, 3), np.uint8)
    colors = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),
              (255,0,255),(255,0,0),(0,0,255),(0,0,0)]
    bw = W // len(colors)
    for i, c in enumerate(colors):
        rgb[:, i*bw:(i+1)*bw] = c
    rgb[:, len(colors)*bw:] = colors[-1]
    return rgb

def main():
    a = sys.argv[1:]
    if a and a[0] == "selftest":
        rgb = make_bars()
        data = encode_frame(rgb)
        dec = decode_frame(data)
        err = np.abs(rgb.astype(int) - dec.astype(int))
        print(f"frame bytes={len(data)}  tiles={MCUS_X*MCUS_Y}")
        print(f"round-trip mean abs err={err.mean():.3f} max={err.max()} "
              f"(quantisation loss expected small)")
        return
    if not a:
        print(__doc__); return
    if a[0] == "bars":
        rgb = make_bars(); outp = a[1]
    elif a[0] == "solid":
        r, g, b = int(a[1]), int(a[2]), int(a[3]); outp = a[4]
        rgb = np.zeros((H, W, 3), np.uint8); rgb[:] = (r, g, b)
    else:
        print(__doc__); return
    data = encode_frame(rgb)
    open(outp, "wb").write(data)
    print(f"wrote {outp}  {len(data)} bytes")

if __name__ == "__main__":
    main()
