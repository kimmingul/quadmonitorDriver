import Foundation

public enum NativeFiles {
    public static func write(_ object: [String:Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:path,options:.atomic)
    }
    public static func read(_ path: URL) -> [String:Any]? {
        guard let data=try? Data(contentsOf:path) else { return nil }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }
    public static func touch(_ path: URL) throws { try Data().write(to:path,options:.atomic) }
}

/// One owner per log. At most three ~8 MiB files; no unbounded frame logging.
public final class NativeEventLog {
    let path: URL
    private var handle: FileHandle
    private var bytes=0
    public init(_ path: URL) throws {
        self.path=path
        FileManager.default.createFile(atPath:path.path,contents:nil)
        handle=try FileHandle(forWritingTo:path)
    }
    public func write(_ event: [String:Any]) throws {
        var row=event;row["unix"]=Date().timeIntervalSince1970
        let data=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10])
        if bytes+data.count>8*1024*1024 {
            try handle.close()
            let fm=FileManager.default
            let oldest=URL(fileURLWithPath:path.path+".2")
            if fm.fileExists(atPath:oldest.path) { try fm.removeItem(at:oldest) }
            let previous=URL(fileURLWithPath:path.path+".1")
            if fm.fileExists(atPath:previous.path) { try fm.moveItem(at:previous,to:oldest) }
            try fm.moveItem(at:path,to:previous)
            fm.createFile(atPath:path.path,contents:nil);handle=try FileHandle(forWritingTo:path);bytes=0
        }
        try handle.write(contentsOf:data);bytes+=data.count
    }
    deinit { try? handle.close() }
}
