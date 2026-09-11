/* Run with AddressSanitizer + UndefinedBehaviorSanitizer on a vendor fixture. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "FrameEncoder.h"
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    FILE *f=fopen(argv[1],"rb");if(!f)return 2;
    fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);
    if(n<=0 || n>1000000)return 2;
    uint8_t *original=malloc((size_t)n),*data=malloc((size_t)n);
    uint16_t out[6];if(!original || !data)return 2;
    if(fread(original,1,(size_t)n,f)!=(size_t)n)return 2;
    fclose(f);
    for(size_t length=0;length<=(size_t)n;length++) {
        out[0]=12345;out[5]=54321;
        racer_validate_frame(original,length,64,16,1,out+1,4);
        if(out[0]!=12345 || out[5]!=54321)return 1;
    }
    uint32_t rng=20260907;
    for(unsigned trial=0;trial<20000;trial++) {
        memcpy(data,original,(size_t)n);
        rng=rng*1664525u+1013904223u;
        data[rng%(size_t)n]^=(uint8_t)(1u<<(trial%8));
        out[0]=12345;out[5]=54321;
        racer_validate_frame(data,(size_t)n,64,16,trial%2,out+1,trial%5);
        if(out[0]!=12345 || out[5]!=54321)return 1;
    }
    racer_validate_frame(NULL,0,64,16,1,out+1,4);
    racer_validate_frame(original,(size_t)n,UINT32_MAX,UINT32_MAX,1,out+1,4);
    free(data);free(original);puts("sanitizer corpus passed");return 0;
}
