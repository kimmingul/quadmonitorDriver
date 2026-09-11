import Foundation
import Metal

/// Serial encoder ownership. Shared buffers are reused only after GPU completion.
/// Integer BGRA comparisons preserve the exact CPU mask, including alpha changes.
public final class MetalTileDiffer: @unchecked Sendable {
    public enum Failure: Error { case unavailable, allocation, execution(String), invalidPixels }
    private let lock=NSLock()
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let buffers: [any MTLBuffer]
    private let width: Int, height: Int
    public let deviceName: String
    public static let available = MTLCreateSystemDefaultDevice() != nil

    public init(width: Int, height: Int) throws {
        guard width>0, height>0, width%32==0, height%8==0,
              width<=65536, height<=65536, (width/32)*(height/8)<=65536 else { throw Failure.invalidPixels }
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw Failure.unavailable }
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        kernel void changes(device const uint *current [[buffer(0)]],
            device const uint *a [[buffer(1)]], device const uint *b [[buffer(2)]],
            device uchar *mask [[buffer(3)]], constant uint &width [[buffer(4)]],
            uint tid [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]]) {
            uint tile=tid/32, col=tid%32, base=(tile/(width/32))*8*width+(tile%(width/32))*32+col;
            bool changed=false;
            for(uint row=0;row<8;row++) {
                uint i=base+row*width;
                changed=changed || current[i]!=a[i] || current[i]!=b[i];
            }
            bool anyChanged=simd_any(changed);
            if(lane==0) mask[tile]=anyChanged ? 1 : 0;
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        guard let function=library.makeFunction(name:"changes") else { throw Failure.unavailable }
        let pipeline=try device.makeComputePipelineState(function:function)
        guard pipeline.threadExecutionWidth==32 else { throw Failure.unavailable }
        let sizes=[width*height*4,width*height*4,width*height*4,(width/32)*(height/8)]
        let buffers=try sizes.map { size -> any MTLBuffer in
            guard let buffer=device.makeBuffer(length:size,options:.storageModeShared) else { throw Failure.allocation }
            return buffer
        }
        self.width=width; self.height=height; self.queue=queue; self.pipeline=pipeline
        self.buffers=buffers; self.deviceName=device.name
    }

    public func changes(current: Data, first: Data, second: Data) throws -> [UInt8] {
        lock.lock();defer { lock.unlock() }
        let size=width*height*4
        guard [current.count,first.count,second.count].allSatisfy({$0==size}) else { throw Failure.invalidPixels }
        for (index,data) in [current,first,second].enumerated() {
            data.withUnsafeBytes { raw in buffers[index].contents().copyMemory(from:raw.baseAddress!,byteCount:size) }
        }
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw Failure.allocation }
        encoder.setComputePipelineState(pipeline)
        for i in buffers.indices { encoder.setBuffer(buffers[i],offset:0,index:i) }
        var w=UInt32(width);encoder.setBytes(&w,length:4,index:4)
        let count=(width/32)*(height/8)
        encoder.dispatchThreads(MTLSize(width:count*32,height:1,depth:1),
                                threadsPerThreadgroup:MTLSize(width:min(256,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1))
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.execution(command.error?.localizedDescription ?? "GPU comparison failed") }
        return Array(UnsafeBufferPointer(start:buffers[3].contents().assumingMemoryBound(to:UInt8.self),count:count))
    }
}
