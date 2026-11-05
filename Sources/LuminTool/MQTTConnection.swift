import Foundation
import Network
import LuminToolCore

extension TokenStore {
    static let mqttService = "local.nortido.LuminTool.mqtt"
}

private final class Link: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.nortido.LuminTool.mqtt")
    private let lock = NSLock()
    private var cancelled = false

    init(_ endpoint: MQTTEndpoint) {
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!,
                                  using: endpoint.tls ? NWParameters.tls : NWParameters.tcp)
    }

    func cancel() {
        lock.withLock { cancelled = true }
        connection.cancel()
    }

    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // A connection cancelled before start reports no state, so a pre-cancel must resume here
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: LuminToolError.message(L("The MQTT broker closed the connection.")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LuminToolError.message(L("The MQTT broker closed the connection.")))
                }
            }
        }
    }
}

@MainActor
final class MQTTConnection {
    @MainActor private final class Health {
        var lastReceived = ProcessInfo.processInfo.systemUptime
        var ready = false
        var timedOut = false
    }
    var onLux: ((Double?) -> Void)?
    var onStatus: ((String) -> Void)?
    private let clientID = "LuminTool-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    private var task: Task<Void, Never>?
    private var link: Link?

    deinit {
        task?.cancel()
        link?.cancel()
    }

    func stop() {
        task?.cancel()
        task = nil
        link?.cancel()
        link = nil
        onLux?(nil)
    }

    func start(endpoint: MQTTEndpoint, username: String, password: String, topic: String, keyPath: String) {
        stop()
        let onLux = onLux
        let onStatus = onStatus
        let clientID = clientID
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                onStatus?(L("Connecting to MQTT…"))
                do {
                    try await Self.session(endpoint: endpoint, username: username, password: password, topic: topic,
                                           keyPath: keyPath, clientID: clientID, onLink: { [weak self] in self?.link = $0 },
                                           onLux: onLux, onStatus: onStatus)
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

    private static func session(endpoint: MQTTEndpoint, username: String, password: String, topic: String, keyPath: String,
                                clientID: String, onLink: (Link) -> Void, onLux: ((Double?) -> Void)?,
                                onStatus: ((String) -> Void)?) async throws {
        let link = Link(endpoint)
        onLink(link)
        let health = Health()
        let started = health.lastReceived
        let watchdog = Task { @MainActor in
            var lastPing = started
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                if (!health.ready && now - started > 20) || now - health.lastReceived > 35 {
                    health.timedOut = true
                    link.cancel()
                    return
                }
                if health.ready && now - lastPing >= 15 {
                    lastPing = now
                    do { try await link.send(MQTT.pingRequest) } catch { link.cancel(); return }
                }
            }
        }
        defer {
            watchdog.cancel()
            link.cancel()
        }
        do {
            try await link.ready()
            try Task.checkCancellation()
            try await link.send(MQTT.connect(clientID: clientID, username: username, password: password, keepAlive: 30))
            try Task.checkCancellation()
            var reader = MQTTFrameReader()
            var accepted = false
            var invalid = false
            while true {
                let chunk = try await link.receive()
                try Task.checkCancellation()
                health.lastReceived = ProcessInfo.processInfo.systemUptime
                for packet in try reader.append(chunk) {
                    switch packet {
                    case .connAck(let code):
                        switch code {
                        case 0:
                            accepted = true
                            try await link.send(MQTT.subscribe(packetID: 1, topic: topic))
                            try Task.checkCancellation()
                        case 4, 5:
                            onLux?(nil)
                            onStatus?(L("MQTT login rejected. Check the login and password."))
                            return
                        default:
                            throw LuminToolError.message(String(format: L("The MQTT broker refused the connection (%d)."), Int(code)))
                        }
                    case .subAck(let id, let codes):
                        guard accepted, id == 1 else { continue }
                        guard let granted = codes.first, granted <= 2 else {
                            throw LuminToolError.message(L("The MQTT broker rejected the topic."))
                        }
                        health.ready = true
                        onStatus?(L("MQTT connected"))
                    case .publish(let name, let payload):
                        guard accepted, name == topic else { continue }
                        if let lux = PayloadLux.value(payload, keyPath: keyPath) {
                            onLux?(lux)
                            if invalid {
                                invalid = false
                                onStatus?(L("MQTT connected"))
                            }
                        } else {
                            onLux?(nil)
                            if !invalid {
                                invalid = true
                                onStatus?(L("The message has no valid illuminance value."))
                            }
                        }
                    case .pingResp, .other:
                        break
                    }
                }
            }
        } catch {
            if health.timedOut, !Task.isCancelled { throw LuminToolError.message(L("The MQTT broker did not answer.")) }
            throw error
        }
    }
}
