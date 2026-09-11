#ifndef RACER_FRAME_ENCODER_H
#define RACER_FRAME_ENCODER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
ptrdiff_t racer_validate_frame(const uint8_t *data, size_t size, uint32_t width, uint32_t height,
    int keyframe, uint16_t *positions, size_t capacity);
size_t racer_configuration_quantization(uint8_t *output, size_t capacity);

/* BGRA8888, opaque pixels. Width divisible by 32, height by 8; <=65536 tiles.
 * mask: one byte per tile (NULL selects all). Caller owns all buffers.
 * Returns byte count, 0 for empty selection, or -1 for invalid input/capacity.
 * On error, output is incomplete and MUST NOT be transmitted. No shared state. */
size_t racer_frame_capacity(unsigned width, unsigned height);
/* OR exact BGRA changes into a tile mask; tightly packed equal-size images.
 * Returns 0 on success, -1 on invalid input without touching the mask. */
int racer_mark_changed_tiles(const uint8_t *current, const uint8_t *previous,
    size_t pixels_size, unsigned width, unsigned height, uint8_t *mask, size_t mask_size);
ptrdiff_t racer_encode_bgra(const uint8_t *pixels, size_t pixels_size,
    unsigned width, unsigned height, size_t stride,
    const uint8_t *mask, size_t mask_size, uint8_t *output, size_t capacity);
/* Explicit CPU task count 1..8; 1 disables parallel encoding. No global state. */
ptrdiff_t racer_encode_bgra_workers(const uint8_t *pixels, size_t pixels_size,
    unsigned width, unsigned height, size_t stride,
    const uint8_t *mask, size_t mask_size, uint8_t *output, size_t capacity, unsigned workers);
#ifdef __cplusplus
}
#endif
#endif
