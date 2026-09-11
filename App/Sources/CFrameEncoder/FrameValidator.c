/* Full tile-container / JPEG entropy validation. Independent Python oracle:
 * tests/support/frame_protocol.py and jpeg_codec.py. No USB or pixel writes.
 * The decoded coefficients are not stored because validation consumes syntax only.
 */
#include <stddef.h>
#include <stdint.h>
#include "include/FrameEncoder.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif
#include "Tables.h"

size_t racer_configuration_quantization(uint8_t *output,size_t capacity) {
    if(!output || capacity<138)return 0;
    for(unsigned table=0;table<2;table++) {
        size_t o=table*69;
        output[o]=0xff;output[o+1]=0xdb;output[o+2]=0;output[o+3]=0x43;output[o+4]=table;
        for(unsigned i=0;i<64;i++)output[o+5+i]=table?DQT_CHROMA_NATURAL[i]:DQT_LUMA_NATURAL[i];
    }
    return 138;
}

typedef struct { uint16_t child[2]; int16_t symbol; } Node;
typedef struct { uint16_t node; uint8_t bits; } Prefix;
typedef struct { Node nodes[512]; unsigned used; Prefix prefix[256]; } Tree;
static Tree trees[4];
#ifdef _WIN32
static INIT_ONCE once=INIT_ONCE_STATIC_INIT;
#else
static pthread_once_t once=PTHREAD_ONCE_INIT;
#endif
static int initialized;

static int make_tree(Tree *t,const Huffman *codes) {
    t->used=1;
    for(unsigned i=0;i<512;i++)t->nodes[i].symbol=-1;
    for(unsigned s=0;s<256;s++) {
        unsigned n=codes[s].length,node=0;
        if(!n)continue;
        if(n>16)return 0;
        for(unsigned b=n;b>0;b--) {
            unsigned bit=(codes[s].code>>(b-1))&1;
            if(t->nodes[node].symbol>=0)return 0;
            if(!t->nodes[node].child[bit]) {
                if(t->used>=512)return 0;
                t->nodes[node].child[bit]=(uint16_t)t->used++;
            }
            node=t->nodes[node].child[bit];
        }
        if(t->nodes[node].symbol>=0 || t->nodes[node].child[0] || t->nodes[node].child[1])return 0;
        t->nodes[node].symbol=(int16_t)s;
    }
    // Every prefix stores the same node reached by the bit-by-bit decoder.
    for(unsigned prefix=0;prefix<256;prefix++) {
        unsigned node=0,depth=0;
        do {
            node=t->nodes[node].child[(prefix>>(7-depth))&1];
            depth++;
        } while(node && t->nodes[node].symbol<0 && depth<8);
        t->prefix[prefix]=(Prefix){(uint16_t)node,(uint8_t)depth};
    }
    return 1;
}
static void initialize(void) {
    initialized=make_tree(&trees[0],ENC_DCL) && make_tree(&trees[1],ENC_ACL) &&
                make_tree(&trees[2],ENC_DCC) && make_tree(&trees[3],ENC_ACC);
}
#ifdef _WIN32
static BOOL CALLBACK initialize_windows(PINIT_ONCE block,PVOID parameter,PVOID *context) {
    (void)block;(void)parameter;(void)context;
    initialize();
    // Publish even a failed table build once; callers reject via initialized.
    return TRUE;
}
#endif
typedef struct { const uint8_t *data; size_t size,pos; unsigned bit; } Reader;
static inline int read_bit(Reader *r) {
    if(r->pos>=r->size)return -1;
    uint8_t byte=r->data[r->pos];int bit=(byte>>(7-r->bit))&1;
    if(++r->bit==8) {
        r->bit=0;r->pos++;
        if(byte==255 && r->pos<r->size && r->data[r->pos]==0)r->pos++;
    }
    return bit;
}
static inline int amplitude(Reader *r,unsigned bits) {
    // Consume by bytes, retaining the exact original FF/00 stuffing behavior.
    while(bits) {
        if(r->pos>=r->size)return 0;
        unsigned take=8-r->bit;
        if(take>bits)take=bits;
        r->bit+=take;bits-=take;
        if(r->bit==8) {
            uint8_t byte=r->data[r->pos++];r->bit=0;
            if(byte==255 && r->pos<r->size && r->data[r->pos]==0)r->pos++;
        }
    }
    return 1;
}
static inline int peek_eight(const Reader *r) {
    if(r->pos>=r->size)return -1;
    unsigned first=r->data[r->pos];
    if(!r->bit)return (int)first;
    size_t next=r->pos+1;
    if(first==255 && next<r->size && r->data[next]==0)next++;
    if(next>=r->size)return -1;
    return (int)(((first<<8)|r->data[next])>>(8-r->bit))&255;
}
static inline int symbol(Reader *r,const Tree *t) {
    unsigned node=0,depth=0;
    int first=peek_eight(r);
    if(first>=0) {
        Prefix p=t->prefix[first];node=p.node;depth=p.bits;
        if(!node || !amplitude(r,depth))return -1;
        if(t->nodes[node].symbol>=0)return t->nodes[node].symbol;
    }
    // Long codes and short tails use the original exact tree walk.
    for(;depth<16;depth++) {
        int b=read_bit(r);if(b<0)return -1;
        node=t->nodes[node].child[b];if(!node)return -1;
        if(t->nodes[node].symbol>=0)return t->nodes[node].symbol;
    }
    return -1;
}
static int entropy(const uint8_t *data,size_t size) {
    Reader r={data,size,0,0};
    for(unsigned block=0;block<12;block++) {
        unsigned table=block%3==0?0:2;
        int dc=symbol(&r,&trees[table]);
        if(dc<0 || !amplitude(&r,(unsigned)dc))return 0;
        unsigned k=1;
        while(k<64) {
            int ac=symbol(&r,&trees[table+1]);if(ac<0)return 0;
            unsigned run=(unsigned)ac>>4,bits=(unsigned)ac&15;
            if(!bits) {
                if(run==15){k+=16;continue;}
                break;
            }
            k+=run;
            if(k>=64 || !amplitude(&r,bits))return 0;
            k++;
        }
    }
    size_t end=r.pos+(r.bit?1:0);
    return end<=size && size-end>=2 && size-end<=5 && data[end]==255 && data[end+1]==217;
}

/* Returns tile count, or -1 for invalid arguments/frame. Output may be partial
 * on error; callers must discard it. Bounds are checked before every write. */
ptrdiff_t racer_validate_frame(const uint8_t *data,size_t size,uint32_t width,uint32_t height,
                            int keyframe,uint16_t *positions,size_t capacity) {
    if(!data || !positions || !width || !height || width%32 || height%8)return -1;
    uint64_t total=(uint64_t)(width/32)*(height/8);
    if(total>65536 || capacity<total)return -1;
#ifdef _WIN32
    if(!InitOnceExecuteOnce(&once,initialize_windows,NULL,NULL))return -1;
#else
    pthread_once(&once,initialize);
#endif
    if(!initialized)return -1;
    size_t off=0,count=0;uint32_t previous=0;
    while(off<=size && size-off>=4) {
        uint32_t word=(uint32_t)data[off]|((uint32_t)data[off+1]<<8)|
                      ((uint32_t)data[off+2]<<16)|((uint32_t)data[off+3]<<24);
        if((word&0xf4000003u)!=0xd0000001u)return -1;
        uint32_t index=(word>>10)&65535;
        if(index>=total || (count && index<=previous))return -1;
        size_t length=(((word>>2)&255)+1)*4;
        if(length>size-off-4 || !entropy(data+off+4,length))return -1;
        if(count>=capacity)return -1;
        positions[count++]=(uint16_t)index;previous=index;off+=4+length;
        if(word&(1u<<27)) {
            size_t fill=128-off%128;
            if(size-off!=fill+1)return -1;
            for(size_t i=0;i<fill;i++) {
                static const uint8_t footer[4]={255,217,255,255};
                if(data[off+i]!=footer[i%4])return -1;
            }
            /* Match the Python oracle: final transport byte is length-checked. */
            if(keyframe && count!=total)return -1;
            return (ptrdiff_t)count;
        }
    }
    return -1;
}
