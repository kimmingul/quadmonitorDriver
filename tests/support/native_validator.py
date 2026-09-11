"""Development-only ctypes adapter for the production frame validator."""
import ctypes
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT/'App/Sources/CFrameEncoder/FrameValidator.c']

class NativeValidator:
    def __init__(self,path):
        self.library=ctypes.CDLL(str(path))
        self.function=self.library.racer_validate_frame
        self.function.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_uint32,
                               ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t]
        self.function.restype=ctypes.c_ssize_t

    def __call__(self,data,width=1920,height=1200,keyframe=False):
        if not 0<width<=0xffffffff or not 0<height<=0xffffffff or width%32 or height%8:
            raise ValueError('dimensions must be positive multiples of 32x8')
        total=(width//32)*(height//8)
        if total>65536:raise ValueError('tile count exceeds header index capacity')
        positions=(ctypes.c_uint16*total)()
        result=self.function(data,len(data),width,height,int(keyframe),positions,total)
        if result<0:raise ValueError('invalid tile container or JPEG entropy')
        return list(positions[:result])
