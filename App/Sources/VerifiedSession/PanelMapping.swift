import Foundation
import VerifiedUSB

struct PanelMapping: Codable, Equatable {
    var role: String
    var usbPath: String
    var deviceID: UInt32
    enum CodingKeys: String,CodingKey { case role;case usbPath="usb_path";case deviceID="device_id" }
    static let roles: Set<String>=["right","left","top"]
    static func select(_ rows: [PanelMapping], roles: [String]) throws -> [PanelMapping] {
        guard Set(rows.map(\.role))==Self.roles,rows.count==3,
              Set(rows.map(\.usbPath)).count==3,Set(rows.map(\.deviceID)).count==3,
              rows.allSatisfy({ $0.deviceID>0 && $0.usbPath.range(of:"^\\d+:\\d+(?:\\.\\d+)*$",options:.regularExpression) != nil }),
              !roles.isEmpty,Set(roles).count==roles.count,Set(roles).isSubset(of:Self.roles)
        else { throw NativeError.invalid("distinct confirmed panel paths, IDs and selected roles required") }
        return rows.filter { roles.contains($0.role) }
    }
    static func bind(_ mapping: [PanelMapping], displays: [[String:Any]]) throws -> [String:UInt32] {
        guard displays.count==mapping.count else { throw NativeError.invalid("virtual display count mismatch") }
        var result=[String:UInt32]()
        for display in displays {
            guard let role=display["role"] as? String,mapping.contains(where:{$0.role==role}),result[role]==nil,
                  let value=display["display_id"] as? NSNumber,let id=UInt32(exactly:value.int64Value),id>0,
                  !result.values.contains(id),display["mirrored"] as? Bool == false,
                  display["width"] as? Int == 1920,display["height"] as? Int == 1200
            else { throw NativeError.invalid("each role requires a distinct independent 1920x1200 display") }
            result[role]=id
        }
        return result
    }
    static func missing(_ mapping: [PanelMapping], paths: [String]) -> [String] {
        mapping.filter { row in paths.filter{$0==row.usbPath}.count != 1 }.map(\.usbPath)
    }
}
