import Foundation

public struct SSEEvent: Equatable {
    public let name: String
    public let data: String
}

public struct SSEParser {
    private var name = ""
    private var data: [String] = []
    private var size = 0
    private var dropped = false
    // Same order as the 64 KiB line cap: a faulty device must not grow memory without bound
    private static let maxEventBytes = 256 * 1024

    public init() {}

    public mutating func line(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer {
                name = ""
                data = []
                size = 0
                dropped = false
            }
            guard !dropped, !data.isEmpty else { return nil }
            return SSEEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        guard !line.hasPrefix(":") else { return nil }
        var field = line
        var value = ""
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        }
        switch field {
        case "event": name = value
        case "data":
            size += value.utf8.count
            if size > Self.maxEventBytes {
                dropped = true
                data = []
            } else if !dropped {
                data.append(value)
            }
        default: break
        }
        return nil
    }
}

public struct ESPHomeState: Equatable {
    public let key: String
    public let name: String
    public let isLux: Bool
    public let value: Double?

    public static func parse(_ json: String) -> ESPHomeState? {
        guard let object = object(json) else { return nil }
        let nameID = object["name_id"] as? String
        guard let id = (nameID?.isEmpty == false ? nameID : nil) ?? object["id"] as? String else { return nil }
        let name: String
        if id.hasPrefix("sensor/") {
            name = String(id.dropFirst("sensor/".count))
        } else if id.hasPrefix("sensor-") {
            name = String(id.dropFirst("sensor-".count))
        } else {
            return nil
        }
        guard !name.isEmpty else { return nil }
        let text = ((object["state"] as? String) ?? "").lowercased()
        var value: Double?
        if let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue >= 0 {
            value = number.doubleValue
        }
        return ESPHomeState(key: id, name: name, isLux: text.hasSuffix(" lx") || text.hasSuffix(" lux"), value: value)
    }

    private static func object(_ json: String) -> [String: Any]? {
        func decode(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        if let parsed = decode(json) { return parsed }
        // ESPHome writes a missing reading as a bare NaN, which is not valid JSON
        let repaired = json.replacingOccurrences(of: #"("value"\s*:\s*)-?(?:NaN|Infinity)"#, with: "$1null",
                                                 options: .regularExpression)
        return repaired == json ? nil : decode(repaired)
    }
}

public struct ESPHomeEndpoint {
    public let base: URL
    public let events: URL
    public var address: String { base.absoluteString }

    public init(_ text: String) throws {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw LuminToolError.message(L("Enter a device address like sensor.local or http://192.168.1.20 without a path, login or parameters."))
        }
        components.scheme = scheme
        components.path = ""
        let base = components.url
        components.path = "/events"
        guard let base, let events = components.url else {
            throw LuminToolError.message(L("Enter a device address like sensor.local or http://192.168.1.20 without a path, login or parameters."))
        }
        self.base = base
        self.events = events
    }
}
