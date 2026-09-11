"""Strict RACERTECH tile-container validation before hardware transmission."""
import struct
import jpeg_codec as jc

def validate_frame(data, width=1920, height=1200, keyframe=False):
    if width <= 0 or height <= 0 or width % 32 or height % 8:
        raise ValueError('dimensions must be positive multiples of 32x8')
    total = (width//32)*(height//8)
    positions=[]
    off=0
    while off+4 <= len(data):
        word, = struct.unpack_from('<I', data, off)
        if word & 0xf4000003 != 0xd0000001:
            raise ValueError(f'invalid tile header at {off}')
        index = (word>>10)&65535
        if index >= total or (positions and index <= positions[-1]):
            raise ValueError('out-of-range, duplicate or unordered tile')
        size = (((word>>2)&255)+1)*4
        payload = data[off+4:off+4+size]
        if len(payload) != size:
            raise ValueError('truncated tile')
        try:
            _, end = jc.decode_mcu(payload)
        except (ValueError, EOFError) as error:
            raise ValueError(f'invalid entropy at tile {index}: {error}') from error
        if not 0 <= size-end-2 <= 3:
            raise ValueError('invalid tile alignment bytes')
        positions.append(index)
        off += 4+size
        if word & (1<<27):
            fill = 128-off%128
            tail = data[off:]
            if len(tail) != fill+1 or tail[:-1] != b'\xff\xd9\xff\xff'*(fill//4):
                raise ValueError('invalid frame footer')
            if keyframe and positions != list(range(total)):
                raise ValueError('initial frame must cover every tile')
            return positions
    raise ValueError('missing final tile flag')
