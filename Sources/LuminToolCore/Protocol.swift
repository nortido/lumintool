import Foundation

public enum LuminToolError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct HomeAssistantEndpoint {
    public let base: URL
    public var webSocket: URL {
        var components = URLComponents(url: base.appendingPathComponent("api/websocket"), resolvingAgainstBaseURL: false)!
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw LuminToolError.message(L("Enter an http:// or https:// address without login, password or parameters."))
        }
        components.scheme = components.scheme?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw LuminToolError.message(L("Invalid Home Assistant address.")) }
        base = url
    }
}

public enum Illuminance {
    public static func value(_ state: String?, unit: String?) -> Double? {
        guard ["lx", "lux"].contains(unit?.lowercased() ?? ""), let state,
              let value = Double(state), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public enum SensorChoice {
    public static func entity(selected: String, available: [String]) -> String {
        selected.isEmpty && available.count == 1 ? available[0] : selected
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, russian
    public var id: String { rawValue }

    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .english: return ["en"]
        case .russian: return ["ru"]
        }
    }

    public init(appleLanguages: [String]?) {
        switch appleLanguages?.first?.prefix(2) {
        case "en": self = .english
        case "ru": self = .russian
        default: self = .system
        }
    }
}

public func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
