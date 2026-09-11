# RACERTECH frame format — current verified specification

2026-09-10. Based on [FrameEncoder.c](../App/Sources/CFrameEncoder/FrameEncoder.c), the [Python reference](../tests/support/jpeg_codec.py), [frame validation](../tests/support/frame_protocol.py), [native validation](../App/Sources/CFrameEncoder/FrameValidator.c), and retained vendor fixtures. Read alongside the [USB configuration contract](protocol.md).

## Pixels and tiles

Split 1920×1200 BGRA input into **32×8-pixel tiles**: 60 columns × 150 rows = 9,000 tiles, indexed 0…8999. Each tile contains four horizontally adjacent 8×8 positions; encoding `Y,Cb,Cr` at each position produces 12 blocks. This is JPEG 4:4:4 without chroma subsampling. Earlier descriptions of 16×16/4:2:0 or a 2×2 arrangement were incorrect.

```text
32 x 8 tile = [8x8: Y Cb Cr][8x8: Y Cb Cr][8x8: Y Cb Cr][8x8: Y Cb Cr]
frame       = [header][tile payload] ... [last header][tile payload][footer][extra byte]
```

## Four-byte little-endian header

```text
normal = 0xD0000001 | (tileIndex << 10) | ((payloadDwords - 1) << 2)
last   = 0xD8000001 | (tileIndex << 10) | ((payloadDwords - 1) << 2)
index  = (word >> 10) & 0xFFFF
length = (((word >> 2) & 0xFF) + 1) * 4
```

Length denotes tile payload bytes, excluding the header. The 8-bit dword length field represents 4…1024B. Bit 27 marks the last **transmitted tile**: index 8999 in a full frame, or the final selected tile index in a partial frame. Indices must be in range, strictly increasing, and unique. Initial full-frame validation requires coverage of all 9000 tiles. Counting `00 D0` byte patterns alone can misinterpret the D8 final tile and patterns inside entropy data.

## Tile entropy and DQT

The pipeline is BGRA→Y/Cb/Cr→DCT→natural-order quantization→zigzag→baseline JPEG Annex K Huffman. Maintain a DC predictor per component and **reset it to 0 at the start of each 32×8 tile**. Each component's predictor continues across the four positions within that tile.

Bits are MSB-first; stuff `00` after entropy `FF`. Fill the final partial byte with **zero bits**, then append `FF D9` EOI and 0–3 zero bytes for dword alignment. These rules and the container mean that stripping a standard JPEG file's headers does not produce a valid device frame.

Quantization tables are a separate 138B natural-order DQT sent over USB control OUT. Distinguish this from the zigzag ordering used when constructing JPEG file tables. Exact constants are in `jpeg_codec.py` and `Tables.h`. We do not claim byte-exact agreement with the vendor's color conversion/DCT for every RGB input. Re-encoding identical coefficients, native/reference output agreement, and independent libjpeg pixel checks are distinct checks.

## Footer and extra byte

Let `count` be the accumulated byte count after the final payload:

```text
fill = 128 - (count % 128)
footer = (FF D9 FF FF) repeated (fill / 4) times
encoded frame = tiles + footer + 00
```

Add a 128B footer even when already at a 128B boundary. The current encoder initializes the final extra byte to zero. Total transfer length always satisfies `length % 128 == 1`. The validator checks the footer structure and the existence of the extra byte but does not require that byte's value to be zero. Do not describe generation rules and acceptance checks as identical. Do not remove the historical `length+1` requirement or reuse an implementation that reads one byte beyond its buffer.

## Partial updates and performance options

The first two transfers are full frames. Thereafter select any tile whose current BGRA differs from either successful history. Send no frame when no tiles are selected and both histories have settled. The same generation may need another transfer to settle both histories. Advance history only after exact, complete USB transfer; invalidate it on partial failure.

CPU workers 1/2/4/8 and CPU/Metal change detection preserve this format. Full mode selects all 9,000 tiles on a change but becomes idle after the screen settles. All compression uses the same JPEG444 codec; the current path has no H.264/HEVC/AV1 or GPU video encoder.

## Validation levels

Validation used complete tile/entropy/footer checks on original fixtures, a machine-code oracle, and independent libjpeg pixel checks. The [decision record](decisions.md) corrects the earlier conclusion that agreement between a faulty encoder and decoder proved complete correctness. Tile-format compliance, complete USB transfer, and actual panel display are separate acceptance conditions. See [current status](current-status.md) for version-specific evidence.

## Historical evidence

Original audits and experiment records are under `project/research/` in the [external archive](archive.md). Current test inputs remain in the [minimal fixture set](../tests/fixtures/README.md).
