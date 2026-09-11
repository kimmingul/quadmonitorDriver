"""Deterministic synthetic inputs, independent of our encoder implementation."""
import numpy as np

def pattern(name):
    if name=='geometry':
        y,x=np.indices((16,64))
        gray=((y//8)*8+x//8)*16
        return np.repeat(gray[:,:,None],3,axis=2).astype(np.uint8)
    if name=='ac_pattern':
        y,x=np.indices((16,64))
        return np.stack(((3*x+2*y)%256,(2*x+9*y)%256,(x+7*y)%256),axis=2).astype(np.uint8)
    if name=='aligned_footer':
        return np.zeros((16,256,3),np.uint8)
    raise ValueError(name)
