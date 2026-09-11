#include "FrameEncoder.h"
#include "Tables.h"
#include <math.h>
#include <string.h>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <fenv.h>
#endif

int racer_mark_changed_tiles(const uint8_t *current, const uint8_t *previous,
    size_t pixels_size, unsigned width, unsigned height, uint8_t *mask, size_t mask_size) {
    size_t capacity = racer_frame_capacity(width, height);
    uint64_t required = (uint64_t)width * height * 4;
    size_t tiles = (size_t)(width / 32) * (height / 8);
    if (!capacity || !current || !previous || !mask || required > pixels_size || mask_size < tiles)
        return -1;
    size_t stride = (size_t)width * 4;
    // Scan contiguous unchanged rows once. Cursor-sized edits then require
    // tile comparisons only in the few changed rows, not 8 calls per tile.
    for (unsigned y = 0; y < height; y++) {
        size_t row = (size_t)y * stride;
        if (memcmp(current + row, previous + row, stride) == 0) continue;
        for (unsigned x = 0; x < width / 32; x++) {
            size_t i = (size_t)(y / 8) * (width / 32) + x;
            if (!mask[i] && memcmp(current + row + x * 128, previous + row + x * 128, 128) != 0)
                mask[i] = 1;
        }
    }
    return 0;
}

size_t racer_frame_capacity(unsigned w, unsigned h) {
    if (!w || !h || w % 32 || h % 8) return 0;
    uint64_t tiles = (uint64_t)(w / 32) * (h / 8);
    return tiles <= 65536 ? (size_t)tiles * 1028 + 129 : 0;
}

typedef struct {
    uint8_t bytes[1024];
    size_t count;
    uint32_t bits;
    unsigned pending;
    int failed;
} Writer;

static void byte(Writer *w, unsigned b) {
    if (w->count == sizeof(w->bytes)) { w->failed = 1; return; }
    w->bytes[w->count++] = (uint8_t)b;
}

static void bits(Writer *w, unsigned value, unsigned length) {
    if (length > 16) { w->failed = 1; return; }
    w->bits = (w->bits << length) | (value & ((1u << length) - 1));
    w->pending += length;
    while (w->pending >= 8) {
        w->pending -= 8;
        unsigned b = (w->bits >> w->pending) & 255;
        byte(w, b);
        if (b == 255) byte(w, 0);
    }
    w->bits &= (1u << w->pending) - 1;
}

static unsigned magnitude(int value) {
    unsigned a = (unsigned)(value < 0 ? -value : value), n = 0;
    while (a) { n++; a >>= 1; }
    return n;
}

static void symbol(Writer *w, const Huffman *table, unsigned s) {
    if (s > 255 || !table[s].length) { w->failed = 1; return; }
    bits(w, table[s].code, table[s].length);
}

static void block(Writer *w, const int *q, int *predictor, int luma) {
    const Huffman *dc = luma ? ENC_DCL : ENC_DCC;
    const Huffman *ac = luma ? ENC_ACL : ENC_ACC;
    int diff = q[0] - *predictor;
    *predictor = q[0];
    unsigned size = magnitude(diff);
    symbol(w, dc, size);
    bits(w, (unsigned)(diff < 0 ? diff - 1 : diff), size);
    unsigned run = 0;
    for (unsigned k = 1; k < 64; k++) {
        int value = q[ZIGZAG[k]];
        if (!value) { run++; continue; }
        while (run >= 16) { symbol(w, ac, 240); run -= 16; }
        size = magnitude(value);
        if (size > 10) { w->failed = 1; return; }
        symbol(w, ac, (run << 4) | size);
        bits(w, (unsigned)(value < 0 ? value - 1 : value), size);
        run = 0;
    }
    if (run) symbol(w, ac, 0);
}

/* Separable orthonormal DCT. No fast-math: rounding affects entropy symbols. */
static void quantize(const double *pixels, const uint8_t *table, int *q) {
    double temp[64];
    int constant = 1;
    for (unsigned i = 1; i < 64; i++) if (pixels[i] != pixels[0]) { constant = 0; break; }
    if (constant) {
        memset(q, 0, 64 * sizeof(*q));
        q[0] = (int)lrint(pixels[0] * 8 / table[0]);
        return;
    }
    for (unsigned u = 0; u < 8; u++) for (unsigned x = 0; x < 8; x++) {
        double sum = 0;
        for (unsigned y = 0; y < 8; y++) sum += BASIS[u][y] * pixels[y*8+x];
        temp[u*8+x] = sum;
    }
    for (unsigned u = 0; u < 8; u++) for (unsigned v = 0; v < 8; v++) {
        double sum = 0;
        for (unsigned x = 0; x < 8; x++) sum += temp[u*8+x] * BASIS[v][x];
        q[u*8+v] = (int)lrint(sum / table[u*8+v]);
    }
}

static void tile(Writer *writer, const uint8_t *p, size_t stride) {
    int predictors[3] = {0};
    for (unsigned pos = 0; pos < 4; pos++) {
        double planes[3][64];
        for (unsigned y = 0; y < 8; y++) for (unsigned x = 0; x < 8; x++) {
            const uint8_t *pixel = p + y * stride + (pos*8+x)*4;
            double b = pixel[0], g = pixel[1], r = pixel[2];
            unsigned k = y*8+x;
            planes[0][k] = .299*r + .587*g + .114*b - 128;
            planes[1][k] = -.168736*r - .331264*g + .5*b;
            planes[2][k] = .5*r - .418688*g - .081312*b;
        }
        for (unsigned component = 0; component < 3; component++) {
            int q[64];
            quantize(planes[component], component ? DQT_CHROMA_NATURAL : DQT_LUMA_NATURAL, q);
            block(writer, q, &predictors[component], component == 0);
        }
    }
    if (writer->pending) bits(writer, 0, 8 - writer->pending);
    byte(writer, 255); byte(writer, 217);
    while (writer->count % 4) byte(writer, 0);
}

#ifdef __APPLE__
/* Fixed slots in the caller's maximum-sized output buffer are temporary storage.
 * Each worker owns different slots; only the calling thread packs/transmits. */
typedef struct {
    const uint8_t *pixels, *mask;
    unsigned width, workers;
    size_t stride, tiles;
    uint8_t *output;
    uint16_t *lengths;
    int rounding;
} ParallelTiles;

static void encode_tile_chunk(void *opaque, size_t worker) {
    ParallelTiles *work = opaque;
    int previous_rounding = fegetround();
    fesetround(work->rounding);
    for (size_t start = worker * 64; start < work->tiles; start += work->workers * 64) {
        size_t end = start + 64 < work->tiles ? start + 64 : work->tiles;
        for (size_t i = start; i < end; i++) {
            if (work->mask && !work->mask[i]) continue;
            Writer writer = {0};
            tile(&writer, work->pixels + (i / (work->width / 32)) * 8 * work->stride +
                 (i % (work->width / 32)) * 128, work->stride);
            if (writer.failed) { work->lengths[i] = UINT16_MAX; continue; }
            work->lengths[i] = (uint16_t)writer.count;
            memcpy(work->output + i * 1028 + 4, writer.bytes, writer.count);
        }
    }
    fesetround(previous_rounding);
}

static ptrdiff_t encode_parallel(const uint8_t *p, unsigned w, size_t stride,
    const uint8_t *mask, uint8_t *out, size_t tiles, size_t last, unsigned workers) {
    uint16_t *lengths = calloc(tiles, sizeof(*lengths));
    if (!lengths) return -1;
    ParallelTiles work = {p, mask, w, workers, stride, tiles, out, lengths, fegetround()};
    dispatch_apply_f(work.workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                     &work, encode_tile_chunk);
    size_t count = 0;
    for (size_t i = 0; i <= last; i++) {
        if (mask && !mask[i]) continue;
        size_t length = lengths[i];
        if (!length || length == UINT16_MAX) { free(lengths); return -1; }
        uint32_t header = (i == last ? 0xd8000001u : 0xd0000001u) |
            ((uint32_t)i << 10) | ((uint32_t)(length / 4 - 1) << 2);
        for (unsigned j = 0; j < 4; j++) out[count++] = (uint8_t)(header >> (8*j));
        /* Destination never extends into the next slot; memmove handles overlap. */
        memmove(out + count, out + i * 1028 + 4, length);
        count += length;
    }
    free(lengths);
    size_t fill = 128 - count % 128;
    const uint8_t footer[4] = {255,217,255,255};
    for (size_t i = 0; i < fill; i++) out[count++] = footer[i%4];
    out[count++] = 0;
    return (ptrdiff_t)count;
}
#endif

ptrdiff_t racer_encode_bgra_workers(const uint8_t *p, size_t n, unsigned w, unsigned h,
    size_t stride, const uint8_t *mask, size_t mask_size, uint8_t *out, size_t cap, unsigned workers) {
    if (workers < 1 || workers > 8) return -1;
    if (!racer_frame_capacity(w,h) || !p || !out || stride < (size_t)w*4 ||
        stride > SIZE_MAX/h || n < stride*h) return -1;
    size_t tiles = (size_t)(w/32)*(h/8);
    if (mask && mask_size < tiles) return -1;
    size_t last = tiles, selected = 0;
    for (size_t i = 0; i < tiles; i++) if (!mask || mask[i]) { last = i; selected++; }
    if (last == tiles) return 0;
#ifdef __APPLE__
    if (workers > 1 && selected >= 512 && cap >= racer_frame_capacity(w,h))
        return encode_parallel(p,w,stride,mask,out,tiles,last,workers);
#endif
    size_t count = 0;
    for (size_t i = 0; i <= last; i++) {
        if (mask && !mask[i]) continue;
        Writer writer = {0};
        tile(&writer, p + (i/(w/32))*8*stride + (i%(w/32))*128, stride);
        if (writer.failed || cap-count < 4+writer.count) return -1;
        uint32_t header = (i == last ? 0xd8000001u : 0xd0000001u) |
            ((uint32_t)i << 10) | ((uint32_t)(writer.count/4-1) << 2);
        for (unsigned j = 0; j < 4; j++) out[count++] = (uint8_t)(header >> (8*j));
        memcpy(out+count, writer.bytes, writer.count);
        count += writer.count;
    }
    size_t fill = 128-count%128;
    if (cap-count < fill+1) return -1;
    const uint8_t footer[4] = {255,217,255,255};
    for (size_t i = 0; i < fill; i++) out[count++] = footer[i%4];
    out[count++] = 0;
    return (ptrdiff_t)count;
}

/* Preserve the existing API and its proven default for standalone callers. */
ptrdiff_t racer_encode_bgra(const uint8_t *p, size_t n, unsigned w, unsigned h,
    size_t stride, const uint8_t *mask, size_t mask_size, uint8_t *out, size_t cap) {
    return racer_encode_bgra_workers(p,n,w,h,stride,mask,mask_size,out,cap,4);
}
