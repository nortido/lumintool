import Foundation
import LuminToolCore

extension TokenStore {
    static let esphomeService = "local.nortido.LuminTool.esphome"
}

private final class Gatekeeper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard !username.isEmpty, challenge.previousFailureCount == 0, space.proxyType == nil,
              space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
    }
}

@MainActor
final class ESPHomeConnection {
    @MainActor private final class Discovery {
        enum Phase { case searching, valid, invalid }
        var sensors: [String: LightSensor] = [:]
        var latest: [String: Double] = [:]
        var target: String
        var targetSeen = false
        var decided = false
        var phase = Phase.searching

        init(target: String) { self.target = target }
    }
    var onSensors: (([LightSensor]) -> Void)?
    var onSelection: ((String) -> Void)?
    var onLux: ((Double?) -> Void)?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func stop() {
        task?.cancel()
        task = nil
        onLux?(nil)
    }

    func start(endpoint: ESPHomeEndpoint, username: String, password: String, selected: String) {
        stop()
        let onSensors = onSensors
        let onSelection = onSelection
        let onLux = onLux
        let onStatus = onStatus
        task = Task { @MainActor in
            while !Task.isCancelled {
                onStatus?(L("Connecting to ESPHome…"))
                do {
                    try await Self.session(endpoint: endpoint, username: username, password: password, selected: selected,
                                           onSensors: onSensors, onSelection: onSelection, onLux: onLux, onStatus: onStatus)
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

    private static func session(endpoint: ESPHomeEndpoint, username: String, password: String, selected: String,
                                onSensors: (([LightSensor]) -> Void)?, onSelection: ((String) -> Void)?,
                                onLux: ((Double?) -> Void)?, onStatus: ((String) -> Void)?) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        // Idle watchdog: ESPHome sends a ping event every 10 s, so 35 s of silence means a dead stream
        configuration.timeoutIntervalForRequest = 35
        let session = URLSession(configuration: configuration, delegate: Gatekeeper(username: username, password: password),
                                 delegateQueue: nil)
        let discovery = Discovery(target: selected)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.events)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw LuminToolError.message(L("The ESPHome device closed the connection."))
        }
        if http.statusCode == 401 {
            onLux?(nil)
            onStatus?(L("ESPHome login rejected. Check the login and password."))
            return
        }
        guard http.statusCode == 200 else {
            throw LuminToolError.message(String(format: L("The ESPHome device answered with HTTP %d."), http.statusCode))
        }
        onStatus?(L("Looking for ESPHome sensors…"))

        func publish() {
            onSensors?(discovery.sensors.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        func follow(_ value: Double?) {
            onLux?(value)
            let phase: Discovery.Phase = value == nil ? .invalid : .valid
            guard phase != discovery.phase else { return }
            discovery.phase = phase
            onStatus?(value == nil ? L("The sensor reports no valid illuminance.") : L("ESPHome connected"))
        }
        func decide() {
            discovery.decided = true
            discovery.target = SensorChoice.entity(selected: selected, available: discovery.sensors.keys.sorted())
            guard discovery.sensors[discovery.target] != nil || discovery.targetSeen else {
                onLux?(nil)
                onStatus?(L("Choose an illuminance sensor in Settings."))
                return
            }
            onSelection?(discovery.target)
            follow(discovery.latest[discovery.target])
        }
        func handle(_ event: SSEEvent) {
            guard event.name == "state", let state = ESPHomeState.parse(event.data) else { return }
            if state.isLux, discovery.sensors[state.key] == nil {
                discovery.sensors[state.key] = LightSensor(id: state.key, name: state.name, unit: "lx")
                publish()
            }
            if state.key == discovery.target { discovery.targetSeen = true }
            if state.isLux || state.key == discovery.target { discovery.latest[state.key] = state.value }
            if discovery.decided, state.key == discovery.target { follow(state.value) }
        }

        // A config event lists every entity on one line, so the cap is generous; a longer line is dropped, not parsed
        var lines = LineBuffer(maxLength: 64 * 1024)
        var parser = SSEParser()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            var timerStarted = false
            for try await byte in bytes {
                guard !Task.isCancelled else { return }
                for line in lines.append(CollectionOfOne(byte)) {
                    guard let event = parser.line(line) else { continue }
                    // The first event opens a 2 s window for the initial state burst before auto-picking
                    if !timerStarted {
                        timerStarted = true
                        group.addTask { @MainActor in
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            guard !Task.isCancelled else { return }
                            decide()
                        }
                    }
                    handle(event)
                }
            }
        }
        guard !Task.isCancelled else { return }
        throw LuminToolError.message(L("The ESPHome device closed the connection."))
    }
}
