/* Run under ASan/UBSan; stress real entropy/capacity paths, not a mock codec. */
#include "FrameEncoder.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    uint8_t pixels[16*272], mask[4];
    size_t full = racer_frame_capacity(64,16);
    uint8_t *out = malloc(full+32);
    assert(out);
    unsigned state = 42;
    for (unsigned trial = 0; trial < 1000; trial++) {
        for (size_t i = 0; i < sizeof(pixels); i++) {
            state = state*1664525u+1013904223u;
            pixels[i] = (uint8_t)(state >> 24);
        }
        for (unsigned i = 0; i < 4; i++) mask[i] = (trial >> i)&1;
        size_t cap = trial%3 ? full : trial%full;
        memset(out,0xa5,full+32);
        ptrdiff_t n = racer_encode_bgra(pixels,sizeof(pixels),64,16,272,mask,4,out,cap);
        assert(n < 0 || (size_t)n <= cap);
        if (n > 0) assert(n%128 == 1);
        for (size_t i = cap; i < full+32; i++) assert(out[i] == 0xa5);
    }
    free(out);
    /* Cross the parallel threshold with exact, tight and insufficient buffers. */
    size_t bytes = 1024 * 256 * 4;
    uint8_t *large = malloc(bytes), *selection = malloc(1024);
    size_t maximum = racer_frame_capacity(1024,256);
    uint8_t *encoded = malloc(maximum + 32);
    assert(large && selection && encoded);
    for (size_t i = 0; i < bytes; i++) large[i] = (uint8_t)((i * 17 + i / 4096) % 256);
    for (unsigned selected = 511; selected <= 1024; selected += selected == 511 ? 1 : 512) {
        memset(selection,0,1024);memset(selection + 1024-selected,1,selected);
        ptrdiff_t length = racer_encode_bgra(large,bytes,1024,256,4096,selection,1024,encoded,maximum);
        assert(length > 0);
        size_t capacities[] = {0, (size_t)length-1, (size_t)length, maximum-1, maximum};
        for (unsigned workers = 1; workers <= 8; workers *= 2) {
        for (unsigned i = 0; i < 5; i++) {
            size_t capacity = capacities[i];
            memset(encoded,0xa5,maximum+32);
            ptrdiff_t actual = racer_encode_bgra_workers(large,bytes,1024,256,4096,selection,1024,encoded,capacity,workers);
            assert(actual == (capacity < (size_t)length ? -1 : length));
            for (size_t j = capacity; j < maximum+32; j++) assert(encoded[j] == 0xa5);
        }
    }
    }
    free(encoded);free(selection);free(large);
    puts("1000 randomized stride/mask/capacity cases passed");
    puts("parallel threshold and large buffer canaries passed");
}
