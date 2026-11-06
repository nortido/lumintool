import Foundation

public struct LinkWatchdog {
    public enum Action: Equatable { case wait, ping, timeout }
    private let started: Double
    private var isReady = false
    private var lastPing = 0.0
    private var unanswered: Double?

    public init(now: Double) { started = now }

    public mutating func ready(now: Double) {
        isReady = true
        lastPing = now
        unanswered = nil
    }

    public mutating func received(now: Double) { unanswered = nil }

    // Judged from the last ping, not the last packet: a tick delayed by App Nap must ping first instead of timing out
    public mutating func tick(now: Double) -> Action {
        guard isReady else { return now - started > 20 ? .timeout : .wait }
        if let sent = unanswered, now - sent > 20 { return .timeout }
        guard now - lastPing >= 15 else { return .wait }
        lastPing = now
        if unanswered == nil { unanswered = now }
        return .ping
    }
}

public struct OutageGrace {
    private var since: Double?
    public init() {}

    public mutating func lost(now: Double) -> Bool {
        if since == nil { since = now }
        return now - since! > 60
    }

    public mutating func restored() { since = nil }
}
