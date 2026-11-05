import Foundation

public struct BrightnessCurve: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public var lux: Double
        public var brightness: Double
    }

    public private(set) var points = [
        Point(lux: 0, brightness: 0.12), Point(lux: 10, brightness: 0.2),
        Point(lux: 100, brightness: 0.4), Point(lux: 500, brightness: 0.7),
        Point(lux: 2000, brightness: 1)
    ]
    public private(set) var isCalibrated = false
    public init() {}

    private enum CodingKeys: String, CodingKey { case points, isCalibrated }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([Point].self, forKey: .points)
        isCalibrated = try container.decode(Bool.self, forKey: .isCalibrated)
        guard !points.isEmpty,
              points.allSatisfy({ $0.lux.isFinite && $0.lux >= 0 && $0.brightness.isFinite && (0...1).contains($0.brightness) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.lux < $1.lux && $0.brightness <= $1.brightness }) else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "Invalid calibration")
        }
    }

    public func value(at lux: Double) -> Double {
        let x = log1p(lux.isFinite && lux >= 0 ? lux : 0)
        guard let first = points.first, let last = points.last else { return 0.5 }
        if x <= log1p(first.lux) { return first.brightness }
        for (left, right) in zip(points, points.dropFirst()) where x <= log1p(right.lux) {
            let fraction = (x - log1p(left.lux)) / (log1p(right.lux) - log1p(left.lux))
            return left.brightness + fraction * (right.brightness - left.brightness)
        }
        return last.brightness
    }

    public mutating func learn(lux: Double, brightness: Double) {
        guard lux.isFinite, lux >= 0, brightness.isFinite, (0...1).contains(brightness) else { return }
        points.removeAll { abs(log1p($0.lux) - log1p(lux)) < 0.12 }
        for index in points.indices {
            points[index].brightness = points[index].lux < lux
                ? min(points[index].brightness, brightness) : max(points[index].brightness, brightness)
        }
        points.append(Point(lux: lux, brightness: brightness))
        points.sort { $0.lux < $1.lux }
        isCalibrated = true
    }
}

public struct AdaptiveBrightness {
    public enum Decision: Equatable { case hold, learned, set(Double) }
    public private(set) var curve: BrightnessCurve
    public private(set) var lux: Double?
    private struct Transition {
        let from: Double
        let target: Double
        let startedAt: Double
        var step = 0
    }
    private var transition: Transition?
    private var observed: Double?
    private var pending: (lux: Double, brightness: Double, time: Double)?
    private var automatic: (from: Double, target: Double)?
    public var isSettling: Bool { automatic != nil }
    private var holdUntil = 0.0

    public init(curve: BrightnessCurve = BrightnessCurve()) { self.curve = curve }

    public mutating func sensor(_ value: Double?) {
        let valid = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if valid == nil || lux == nil { resetObservation() }
        lux = valid
    }

    public mutating func resetObservation() {
        observed = nil
        pending = nil
        transition = nil
        holdUntil = 0
    }

    public mutating func acknowledge(brightness: Double, requested: Double) {
        automatic = (observed ?? brightness, requested)
        if let write = automatic,
           brightness < min(write.from, write.target) - 0.0002 || brightness > max(write.from, write.target) + 0.0002 {
            automatic?.target = brightness
        }
        observed = brightness
    }

    public mutating func tick(brightness: Double, now: Double) -> Decision {
        guard let lux, brightness.isFinite, (0...1).contains(brightness) else {
            resetObservation()
            return .hold
        }
        if let write = automatic {
            if abs(brightness - write.target) <= 0.0002 {
                automatic = nil
                observed = brightness
            } else {
                // A manual change inside an unfinished automatic step can't be told from the step, so it is not learned
                if brightness >= min(write.from, write.target) - 0.0002,
                   brightness <= max(write.from, write.target) + 0.0002 {
                    observed = brightness
                    return .hold
                }
                automatic = nil
            }
        }
        guard let previous = observed else {
            observed = brightness
            if !curve.isCalibrated {
                curve.learn(lux: lux, brightness: brightness)
                return .learned
            }
            return .hold
        }
        observed = brightness
        if abs(previous - brightness) > 0.0002 {
            transition = nil
            pending = (lux, brightness, now)
            holdUntil = now + 4
            return .hold
        }
        if let manual = pending {
            guard now - manual.time >= 1 else { return .hold }
            curve.learn(lux: manual.lux, brightness: manual.brightness)
            pending = nil
            return .learned
        }
        guard now >= holdUntil else { return .hold }
        let target = curve.value(at: lux)
        if transition == nil || abs(transition!.target - target) > 0.0002 {
            guard abs(target - brightness) > 0.0002 else { transition = nil; return .hold }
            transition = Transition(from: brightness, target: target, startedAt: now)
            return .hold
        }
        guard var ramp = transition, now + 0.01 >= ramp.startedAt + Double(ramp.step + 1) / 10 else { return .hold }
        ramp.step += 1
        let next = ramp.from + (ramp.target - ramp.from) * Double(ramp.step) / 30
        transition = ramp.step == 30 ? nil : ramp
        return .set(next)
    }
}
