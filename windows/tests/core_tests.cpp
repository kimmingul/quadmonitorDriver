#include "FrameEncoder.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32) && !defined(_M_ARM64) && !defined(__aarch64__)
#error This Windows test target must be compiled for native ARM64.
#endif
using Bytes = std::vector<uint8_t>;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
Bytes readHex(const std::string& path) {
    std::ifstream file(path); require(file.good(), "fixture missing");
    std::string hex; file >> hex;
    require(!hex.empty() && hex.size()%2==0, "invalid hex fixture");
    Bytes bytes;
    for (size_t i=0;i<hex.size();i+=2) bytes.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i,2),nullptr,16)));
    return bytes;
}
Bytes vendorFrame(const std::string& path) {
    auto data=readHex(path);
    require(data.size()%128==0,"vendor encoder output must be 128-aligned");
    // Archived encodeFrame output omits the extra USB transport byte. Preserve
    // the original fixture; use the production encoder's deterministic zero.
    data.push_back(0);return data;
}
Bytes entropy(const Bytes& frame) {
    Bytes result;size_t offset=0;
    while (offset+4<=frame.size()) {
        uint32_t word=0;for(unsigned i=0;i<4;++i) word|=uint32_t(frame[offset+i])<<(8*i);
        const size_t length=(((word>>2)&255)+1)*4;
        require(offset+4+length<=frame.size(),"invalid entropy block length");
        bool found=false;
        for(size_t i=offset+4;i+1<offset+4+length;++i) {
            result.push_back(frame[i]);
            if(frame[i]==255 && frame[i+1]==217) { result.push_back(217);found=true;break; }
        }
        require(found,"EOI missing");offset+=4+length;
        if(word&(1u<<27))return result;
    }
    throw std::runtime_error("end tile missing");
}
ptrdiff_t validate(const Bytes& data, unsigned width=64, bool full=true) {
    std::array<uint16_t,9000> positions{};
    return racer_validate_frame(data.data(),data.size(),width,16,full,positions.data(),positions.size());
}
int main(int argc, char** argv) {
    try {
        require(argc==3,"expected test name and fixtures directory");
        const std::string test=argv[1], dir=argv[2];
        if (test=="concurrent_init") {
            const auto frame=vendorFrame(dir+"/geometry.hex");
            std::array<int,8> results{}; std::vector<std::thread> threads;std::atomic<bool> start{false};
            for (size_t i=0;i<results.size();++i) threads.emplace_back([&,i] {
                while(!start.load())std::this_thread::yield();
                results[i]=1;
                for (int n=0;n<100;++n) if (validate(frame)!=4) results[i]=0;
            });
            start.store(true);
            for (auto& thread:threads) thread.join();
            require(std::all_of(results.begin(),results.end(),[](int x){return x==1;}),"concurrent validation failed");
        } else if (test=="vendor_frames") {
            for (const auto* name:{"geometry","ac_pattern","aligned_footer"}) {
                const auto frame=vendorFrame(dir+"/"+name+".hex");
                const unsigned width=std::string(name)=="aligned_footer" ? 256 : 64;
                require(validate(frame,width)==width/16,"vendor frame rejected");
                for (size_t size=0;size<frame.size();++size) {
                    Bytes truncated(frame.begin(),frame.begin()+size);
                    require(validate(truncated,width)==-1,"truncated frame accepted");
                }
            }
            Bytes dqt(138); require(racer_configuration_quantization(dqt.data(),dqt.size())==138,"DQT size");
            require(dqt==readHex(dir+"/dqt.hex"),"DQT differs from vendor");
        } else if (test=="encoder") {
            Bytes pixels(64*16*4,255), mask(4,1), out(racer_frame_capacity(64,16));
            for (size_t i=0;i<pixels.size();i+=4) pixels[i]=pixels[i+1]=pixels[i+2]=0;
            auto count=racer_encode_bgra_workers(pixels.data(),pixels.size(),64,16,256,nullptr,0,out.data(),out.size(),1);
            require(count>0,"encode failed"); out.resize(static_cast<size_t>(count));
            require(validate(out)==4,"encoded full frame rejected");
            for(unsigned y=0;y<16;++y) for(unsigned x=0;x<64;++x) {
                const auto gray=static_cast<uint8_t>(((y/8)*8+x/8)*16);
                for(unsigned c=0;c<3;++c)pixels[(y*64+x)*4+c]=gray;
            }
            out.resize(racer_frame_capacity(64,16));
            count=racer_encode_bgra_workers(pixels.data(),pixels.size(),64,16,256,nullptr,0,out.data(),out.size(),1);
            require(count>0,"geometry encode failed");out.resize(static_cast<size_t>(count));
            require(entropy(out)==entropy(vendorFrame(dir+"/geometry.hex")),"vendor entropy differs");
            auto previous=pixels;previous[0]=255;pixels.back()=0;mask={0,1,0,0};
            require(racer_mark_changed_tiles(pixels.data(),previous.data(),pixels.size(),64,16,mask.data(),mask.size())==0,"damage failed");
            require(mask==Bytes({1,1,0,1}),"old/new cursor union lost");
            out.resize(racer_frame_capacity(64,16));mask={0,1,0,0};
            count=racer_encode_bgra_workers(pixels.data(),pixels.size(),64,16,256,mask.data(),mask.size(),out.data(),out.size(),1);
            require(count>0,"delta encode failed");out.resize(static_cast<size_t>(count));
            require(validate(out,64,false)==1 && validate(out)==-1,"delta accepted as keyframe");
        } else if (test=="guards") {
            const auto frame=vendorFrame(dir+"/geometry.hex");std::array<uint16_t,4> positions={999,999,999,999};
            require(racer_validate_frame(frame.data(),frame.size(),64,16,1,positions.data(),3)==-1,"capacity accepted");
            require(positions==std::array<uint16_t,4>{999,999,999,999},"output canary overwritten");
            Bytes pixels(64*16*4,0),out(128,90);
            require(racer_encode_bgra_workers(pixels.data(),pixels.size(),64,16,256,nullptr,0,out.data(),1,1)==-1,"tiny output accepted");
            require(std::all_of(out.begin()+1,out.end(),[](uint8_t x){return x==90;}),"encode overflow");
            require(racer_frame_capacity(0,16)==0,"invalid geometry accepted");
        } else throw std::runtime_error("unknown test");
        std::cout<<test<<": PASS\n"; return 0;
    } catch(const std::exception& error) { std::cerr<<error.what()<<'\n';return 1; }
}
