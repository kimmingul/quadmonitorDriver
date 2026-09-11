import Foundation
import VerifiedUSB

signal(SIGPIPE,SIG_IGN)
do {
    if CommandLine.arguments.dropFirst().elementsEqual(["--help"]) {
        print("VerifiedSession: --runtime-check | --device-presence | --run [--send] [--continuous] [--takeover-vendor] [--fps 1..60] [--seconds 2..3600] [--panels right,left,top]")
        exit(0)
    }
    let options=try SessionOptions(Array(CommandLine.arguments.dropFirst()),executable:URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL)
    let mapping=try options.selectedMapping()
    if options.devicePresence {
        let row=try devicePresence(options,mapping)
        print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),as:UTF8.self))
    } else if !options.run {
        let host=try command(options.host.path,["--preflight"])
        let capture=try command(options.capture.path,["--preflight"])
        guard host.status==0,capture.status==0 else { throw NativeError.invalid("native helpers unavailable") }
        let row:[String:Any]=["engine":"native","python_required":false,"usb_paths":try NativeUSB.paths(),
             "host":host.output.trimmingCharacters(in:.whitespacesAndNewlines),
             "capture":capture.output.trimmingCharacters(in:.whitespacesAndNewlines),"panels":mapping.map(\.role)]
        print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),as:UTF8.self))
    } else {
        let source=StopSignal()
        exit(try SessionEngine(options,mapping,signal:source).run())
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)
}
