import Foundation
import Security
import LuminToolCore

enum TokenStore {
    static let homeAssistantService = "local.nortido.LuminTool.homeassistant"

    private static func query(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String, service: String = homeAssistantService) throws -> String? {
        var request = query(account, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw LuminToolError.message(String(format: L("Could not read the token from Keychain (%d)."), status))
        }
        return token
    }

    static func save(_ token: String, account: String, service: String = homeAssistantService) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(account, service: service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LuminToolError.message(String(format: L("Could not update the token (%d)."), status)) }
        var request = query(account, service: service)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw LuminToolError.message(String(format: L("Could not save the token (%d)."), added)) }
    }
}

struct LightSensor: Identifiable {
    let id: String
    let name: String
    let unit: String
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class HomeAssistantConnection {
    @MainActor private final class Health {
        var lastReceived = ProcessInfo.processInfo.systemUptime
        var ready = false
    }
    var onSensors: (([LightSensor]) -> Void)?
    var onSelection: ((String) -> Void)?
    var onLux: ((Double?) -> Void)?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    deinit {
        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onLux?(nil)
    }

    func start(endpoint: HomeAssistantEndpoint, token: String, selected: String) {
        stop()
        let onSensors = onSensors
        let onSelection = onSelection
        let onLux = onLux
        let onStatus = onStatus
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                onStatus?(L("Connecting to Home Assistant…"))
                do {
                    try await Self.connect(endpoint: endpoint, token: token, selected: selected,
                                           onSocket: { [weak self] in self?.socket = $0 }, onSensors: onSensors,
                                           onSelection: onSelection, onLux: onLux, onStatus: onStatus)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    onLux?(nil)
                    onStatus?(String(format: L("No connection: %@"), error.localizedDescription))
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }

    private static func connect(endpoint: HomeAssistantEndpoint, token: String, selected: String,
                                onSocket: (URLSessionWebSocketTask) -> Void, onSensors: (([LightSensor]) -> Void)?,
                                onSelection: ((String) -> Void)?, onLux: ((Double?) -> Void)?,
                                onStatus: ((String) -> Void)?) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint.webSocket)
        socket.maximumMessageSize = 8 * 1024 * 1024
        onSocket(socket)
        socket.resume()
        let health = Health()
        let started = health.lastReceived
        let heartbeat = Task { @MainActor in
            var id = 1000
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                    let now = ProcessInfo.processInfo.systemUptime
                    if (!health.ready && now - started > 20) || now - health.lastReceived > 35 {
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    if health.ready {
                        try await Self.send(["id": id, "type": "ping"], to: socket)
                        id += 1
                    }
                } catch { socket.cancel(with: .goingAway, reason: nil); return }
            }
        }
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        func receive() async throws -> [String: Any] {
            let frame = try await socket.receive()
            try Task.checkCancellation()
            let data: Data
            switch frame {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw LuminToolError.message(L("Unknown response from Home Assistant."))
            }
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LuminToolError.message(L("Invalid response from Home Assistant."))
            }
            health.lastReceived = ProcessInfo.processInfo.systemUptime
            return message
        }
        func command(_ id: Int, type: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
            var request = extra
            request["id"] = id
            request["type"] = type
            try await Self.send(request, to: socket)
            while true {
                let response = try await receive()
                if response["id"] as? Int == id, response["type"] as? String == "result" { return response }
            }
        }

        let greeting = try await receive()
        guard greeting["type"] as? String == "auth_required" else { throw LuminToolError.message(L("The server did not ask for authentication.")) }
        try await Self.send(["type": "auth", "access_token": token], to: socket)
        let auth = try await receive()
        guard auth["type"] as? String == "auth_ok" else {
            onLux?(nil)
            onStatus?(L("Token rejected. Enter a new token in Settings."))
            return
        }
        let response = try await command(2, type: "get_states")
        guard response["success"] as? Bool == true, let states = response["result"] as? [[String: Any]] else {
            throw LuminToolError.message(L("Could not get sensors."))
        }
        let sensors = states.compactMap { state -> LightSensor? in
            guard let id = state["entity_id"] as? String, id.hasPrefix("sensor."),
                  let attrs = state["attributes"] as? [String: Any],
                  let unit = attrs["unit_of_measurement"] as? String,
                  ["lx", "lux"].contains(unit.lowercased()) else { return nil }
            return LightSensor(id: id, name: attrs["friendly_name"] as? String ?? id, unit: unit)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onSensors?(sensors)
        let entity = SensorChoice.entity(selected: selected, available: sensors.map(\.id))
        guard sensors.contains(where: { $0.id == entity }) else {
            onLux?(nil)
            onStatus?(L("Choose an illuminance sensor in Settings."))
            return
        }
        onSelection?(entity)
        try await Self.send(["id": 3, "type": "subscribe_entities", "entity_ids": [entity]], to: socket)
        var state: String?
        var unit: String?
        while true {
            let message = try await receive()
            if message["id"] as? Int == 3, message["type"] as? String == "result" {
                guard message["success"] as? Bool == true else { throw LuminToolError.message(L("Sensor subscription was rejected.")) }
                health.ready = true
                onStatus?(L("Home Assistant connected"))
            }
            guard message["id"] as? Int == 3, message["type"] as? String == "event",
                  let event = message["event"] as? [String: Any] else { continue }
            if let added = (event["a"] as? [String: Any])?[entity] as? [String: Any] {
                state = added["s"] as? String
                unit = (added["a"] as? [String: Any])?["unit_of_measurement"] as? String
            }
            if let changed = (event["c"] as? [String: Any])?[entity] as? [String: Any] {
                if let plus = changed["+"] as? [String: Any] {
                    if let value = plus["s"] as? String { state = value }
                    if let attrs = plus["a"] as? [String: Any], let value = attrs["unit_of_measurement"] {
                        unit = value as? String
                    }
                }
                if let minus = changed["-"] as? [String: Any], let removed = minus["a"] as? [String] {
                    if removed.contains("unit_of_measurement") { unit = nil }
                }
            }
            if (event["r"] as? [String])?.contains(entity) == true { state = nil }
            onLux?(Illuminance.value(state, unit: unit))
        }
    }

    private static func send(_ object: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
