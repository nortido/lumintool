import Foundation

public enum MQTT {
    public static let pingRequest = Data([0xC0, 0x00])

    public static func remainingLength(_ length: Int) -> [UInt8] {
        var rest = length
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(rest % 128)
            rest /= 128
            if rest > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while rest > 0
        return bytes
    }

    public static func connect(clientID: String, username: String?, password: String?, keepAlive: UInt16) -> Data {
        let user = username.flatMap { $0.isEmpty ? nil : $0 }
        let secret = user == nil ? nil : password.flatMap { $0.isEmpty ? nil : $0 }
        var flags: UInt8 = 0x02
        if user != nil { flags |= 0x80 }
        if secret != nil { flags |= 0x40 }
        var body: [UInt8] = [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        body += field(clientID)
        if let user { body += field(user) }
        if let secret { body += field(secret) }
        return Data([0x10] + remainingLength(body.count) + body)
    }

    public static func subscribe(packetID: UInt16, topic: String) -> Data {
        let body = [UInt8(packetID >> 8), UInt8(packetID & 0xFF)] + field(topic) + [0x00]
        return Data([0x82] + remainingLength(body.count) + body)
    }

    private static func field(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(65535))
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }
}

public enum MQTTPacket: Equatable {
    case connAck(UInt8)
    case subAck(UInt16, [UInt8])
    case publish(String, Data)
    case pingResp
    case other(UInt8)
}

public struct MQTTFrameReader {
    private static let maxBody = 1 << 20
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) throws -> [MQTTPacket] {
        buffer += data
        var packets: [MQTTPacket] = []
        var offset = 0
        while offset < buffer.count {
            guard let (length, size) = try Self.remainingLength(buffer, at: offset + 1) else { break }
            guard length <= Self.maxBody else { throw Self.malformed }
            let start = offset + 1 + size
            guard start + length <= buffer.count else { break }
            packets.append(try Self.packet(first: buffer[offset], body: Array(buffer[start..<start + length])))
            offset = start + length
        }
        buffer.removeFirst(offset)
        return packets
    }

    private static var malformed: LuminToolError {
        LuminToolError.message(L("Invalid response from the MQTT broker."))
    }

    private static func remainingLength(_ bytes: [UInt8], at start: Int) throws -> (value: Int, size: Int)? {
        var value = 0
        for index in 0..<4 {
            guard start + index < bytes.count else { return nil }
            let byte = bytes[start + index]
            value += Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return (value, index + 1) }
        }
        throw malformed
    }

    private static func packet(first: UInt8, body: [UInt8]) throws -> MQTTPacket {
        switch first >> 4 {
        case 2:
            guard body.count == 2 else { throw malformed }
            return .connAck(body[1])
        case 3:
            let qos = (first >> 1) & 3
            guard qos < 3, body.count >= 2 else { throw malformed }
            var start = 2 + (Int(body[0]) << 8) + Int(body[1])
            guard start <= body.count, let topic = String(bytes: body[2..<start], encoding: .utf8) else { throw malformed }
            if qos > 0 { start += 2 }
            guard start <= body.count else { throw malformed }
            return .publish(topic, Data(body[start...]))
        case 9:
            guard body.count >= 3 else { throw malformed }
            return .subAck(UInt16(body[0]) << 8 | UInt16(body[1]), Array(body[2...]))
        case 13:
            return .pingResp
        default:
            return .other(first >> 4)
        }
    }
}

public struct MQTTEndpoint {
    public let host: String
    public let port: UInt16
    public let tls: Bool

    public var address: String {
        "\(tls ? "mqtts" : "mqtt")://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    public init(_ text: String) throws {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "mqtt://" + trimmed }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "mqtt" || scheme == "mqtts",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw LuminToolError.message(L("Enter an mqtt:// or mqtts:// address without login, password or parameters."))
        }
        let port = components.port ?? (scheme == "mqtts" ? 8883 : 1883)
        guard (1...65535).contains(port) else {
            throw LuminToolError.message(L("Enter an mqtt:// or mqtts:// address without login, password or parameters."))
        }
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = UInt16(port)
        tls = scheme == "mqtts"
    }
}

public enum MQTTTopic {
    public static func validated(_ text: String) throws -> String {
        let topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, topic.utf8.count <= 65535,
              !topic.unicodeScalars.contains(where: { $0 == "+" || $0 == "#" || $0.value == 0 }) else {
            throw LuminToolError.message(L("Enter an exact topic without + or #."))
        }
        return topic
    }
}

public enum PayloadLux {
    public static func value(_ data: Data, keyPath: String) -> Double? {
        let path = keyPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty, let text = String(data: data, encoding: .utf8), let plain = number(text) { return plain }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if path.isEmpty { return automatic(object) }
        var node: Any = object
        for key in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let next = (node as? [String: Any])?[String(key)] else { return nil }
            node = next
        }
        return number(node)
    }

    private static func automatic(_ object: [String: Any]) -> Double? {
        for name in ["illuminance_lux", "illuminance"] {
            if let found = entry(object, name) { return number(found) }
        }
        let nested = object.values.compactMap { ($0 as? [String: Any]).flatMap { entry($0, "illuminance") } }
        return nested.count == 1 ? number(nested[0]) : nil
    }

    private static func entry(_ object: [String: Any], _ name: String) -> Any? {
        object.first { $0.key.lowercased() == name }?.value
    }

    // JSON true/false bridge to NSNumber 1/0, so they must be excluded by type
    private static func number(_ value: Any) -> Double? {
        let result: Double
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ "0123456789+-.eE".contains($0) }),
                  let parsed = Double(trimmed) else { return nil }
            result = parsed
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            result = number.doubleValue
        } else {
            return nil
        }
        return result.isFinite && result >= 0 ? result : nil
    }
}
