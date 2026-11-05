import XCTest
@testable import LuminToolCore

final class AdaptiveBrightnessTests: XCTestCase {
    func testDimmingTakesThirtyEvenStepsInThreeSeconds() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.8, now: 0)
        engine.sensor(0)
        let target = engine.curve.value(at: 0)
        let saved = engine.curve
        XCTAssertEqual(engine.tick(brightness: 0.8, now: 0.1), .hold)
        var current = 0.8
        for step in 1...30 {
            let now = 0.1 + Double(step) / 10
            guard case let .set(next) = engine.tick(brightness: current, now: now) else {
                return XCTFail("Missing step \(step)")
            }
            XCTAssertEqual(next, 0.8 + (target - 0.8) * Double(step) / 30, accuracy: 0.00001)
            current = Double(Float(next))
            engine.acknowledge(brightness: current, requested: next)
        }
        XCTAssertEqual(current, target, accuracy: 0.00001)
        XCTAssertEqual(engine.tick(brightness: current, now: 3.2), .hold)
        XCTAssertEqual(engine.curve, saved)
    }

    func testRetargetStartsNewRampFromCurrentBrightness() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.8, now: 0)
        engine.sensor(0)
        _ = engine.tick(brightness: 0.8, now: 0.1)
        guard case let .set(first) = engine.tick(brightness: 0.8, now: 0.2) else { return XCTFail("Missing step") }
        engine.acknowledge(brightness: first, requested: first)
        engine.sensor(2000)
        XCTAssertEqual(engine.tick(brightness: first, now: 0.3), .hold)
        guard case let .set(next) = engine.tick(brightness: first, now: 0.4) else { return XCTFail("Missing retarget step") }
        XCTAssertEqual(next, first + (engine.curve.value(at: 2000) - first) / 30, accuracy: 0.00001)
    }

    func testTransitionDoesNotSkipStepsForMillisecondReadJitter() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.8, now: 0)
        engine.sensor(0)
        _ = engine.tick(brightness: 0.8, now: 0.101)
        var current = 0.8
        for step in 1...30 {
            let now = 0.1 + Double(step) / 10 + (step.isMultiple(of: 2) ? 0.004 : 0)
            guard case let .set(next) = engine.tick(brightness: current, now: now) else {
                return XCTFail("Skipped step \(step) for timer jitter")
            }
            current = next
            engine.acknowledge(brightness: current, requested: next)
        }
        XCTAssertEqual(current, engine.curve.value(at: 0), accuracy: 0.00001)
    }

    func testCurveUsesLogLuxAndHonorsManualAnchor() {
        var curve = BrightnessCurve()
        curve.learn(lux: 100, brightness: 0.6)
        XCTAssertEqual(curve.value(at: 100), 0.6, accuracy: 0.0001)
        curve.learn(lux: 10, brightness: 0.8)
        XCTAssertEqual(curve.value(at: 10), 0.8, accuracy: 0.0001)
        for lux in 0..<2000 {
            XCTAssertLessThanOrEqual(curve.value(at: Double(lux)), curve.value(at: Double(lux + 1)))
        }
        XCTAssertEqual(curve.value(at: .infinity), curve.value(at: 0))
        curve.learn(lux: .nan, brightness: 0.1)
        curve.learn(lux: 0, brightness: .nan)
        XCTAssertTrue(curve.value(at: 0).isFinite)
        let restored = try! JSONDecoder().decode(BrightnessCurve.self, from: JSONEncoder().encode(curve))
        XCTAssertEqual(restored.value(at: 10), 0.8, accuracy: 0.0001)
    }

    func testFirstRunKeepsCurrentBrightness() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        XCTAssertEqual(engine.tick(brightness: 0.51, now: 0), .learned)
        XCTAssertEqual(engine.tick(brightness: 0.51, now: 1), .hold)
        XCTAssertEqual(engine.curve.value(at: 100), 0.51, accuracy: 0.0001)
    }

    func testManualChangeIsDebouncedAtLuxWhenUserChangedBrightness() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.5, now: 0)
        XCTAssertEqual(engine.tick(brightness: 0.6, now: 1), .hold)
        engine.sensor(500)
        XCTAssertEqual(engine.tick(brightness: 0.6, now: 1.5), .hold)
        XCTAssertEqual(engine.tick(brightness: 0.6, now: 2.1), .learned)
        XCTAssertEqual(engine.curve.value(at: 100), 0.6, accuracy: 0.0001)
        XCTAssertEqual(engine.tick(brightness: 0.6, now: 3), .hold)
    }

    func testAutomaticWriteDoesNotTeachAndTransitionIsBounded() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.4, now: 0)
        engine.sensor(2000)
        let saved = engine.curve
        XCTAssertEqual(engine.tick(brightness: 0.4, now: 1), .hold)
        guard case let .set(next) = engine.tick(brightness: 0.4, now: 1.1) else {
            return XCTFail("Expected a smooth automatic step")
        }
        XCTAssertGreaterThan(next, 0.4)
        XCTAssertLessThanOrEqual(next, 0.43 + 1e-9)
        engine.acknowledge(brightness: next, requested: next)
        _ = engine.tick(brightness: next, now: 1.5)
        XCTAssertEqual(engine.curve, saved)
    }

    func testUnavailableAndReconnectDoNotLearnManualChanges() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.4, now: 0)
        let saved = engine.curve
        engine.sensor(nil)
        XCTAssertEqual(engine.tick(brightness: 0.9, now: 1), .hold)
        engine.sensor(100)
        XCTAssertEqual(engine.tick(brightness: 0.9, now: 2), .hold)
        XCTAssertEqual(engine.curve, saved)
        engine.resetObservation()
        XCTAssertEqual(engine.tick(brightness: 0.2, now: 3), .hold)
        XCTAssertEqual(engine.curve, saved)
    }

    func testInvalidSensorAndBrightnessNeverCauseWriteOrLearning() {
        var engine = AdaptiveBrightness()
        for invalid in [Double.nan, .infinity, -1] {
            engine.sensor(invalid)
            XCTAssertEqual(engine.tick(brightness: 0.4, now: 0), .hold)
        }
        engine.sensor(10)
        for invalid in [Double.nan, .infinity, -1, 1.1] {
            XCTAssertEqual(engine.tick(brightness: invalid, now: 0), .hold)
        }
        XCTAssertFalse(engine.curve.isCalibrated)
    }

    func testManualKeysInterruptAutomaticTransition() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.4, now: 0)
        engine.sensor(1000)
        engine.acknowledge(brightness: 0.43, requested: 0.43)
        XCTAssertEqual(engine.tick(brightness: 0.35, now: 1), .hold)
        XCTAssertEqual(engine.tick(brightness: 0.30, now: 1.5), .hold)
        XCTAssertEqual(engine.tick(brightness: 0.30, now: 2), .hold)
        XCTAssertEqual(engine.tick(brightness: 0.30, now: 2.6), .learned)
        XCTAssertEqual(engine.curve.value(at: 1000), 0.3, accuracy: 0.0001)
    }

    func testDelayedAutomaticReadbackNeverTeachesItself() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.4, now: 0)
        engine.sensor(2000)
        let saved = engine.curve
        _ = engine.tick(brightness: 0.4, now: 1)
        guard case let .set(target) = engine.tick(brightness: 0.4, now: 1.1) else { return XCTFail("Expected write") }
        engine.acknowledge(brightness: 0.4, requested: target)
        let partial = 0.4 + (target - 0.4) / 3
        XCTAssertEqual(engine.tick(brightness: partial, now: 1.5), .hold)
        XCTAssertEqual(engine.tick(brightness: partial, now: 2.6), .hold)
        XCTAssertEqual(engine.tick(brightness: partial, now: 3), .hold)
        guard case .set = engine.tick(brightness: target, now: 5) else { return XCTFail("Expected next step after acknowledgement") }
        _ = engine.tick(brightness: target, now: 6.1)
        XCTAssertEqual(engine.curve, saved)
    }

    func testRejectedWriteCanBeRetriedAfterObservationReset() {
        var engine = AdaptiveBrightness()
        engine.sensor(100)
        _ = engine.tick(brightness: 0.4, now: 0)
        engine.sensor(2000)
        _ = engine.tick(brightness: 0.4, now: 1)
        guard case .set = engine.tick(brightness: 0.4, now: 1.1) else { return XCTFail("Expected write") }
        engine.resetObservation()
        XCTAssertEqual(engine.tick(brightness: 0.4, now: 2), .hold)
        XCTAssertEqual(engine.tick(brightness: 0.4, now: 2.1), .hold)
        guard case .set = engine.tick(brightness: 0.4, now: 2.2) else { return XCTFail("Expected retry after rejected write") }
    }

    func testCurveKeepsFivePointsAndReplacesNearest() {
        var curve = BrightnessCurve()
        curve.learn(lux: 50, brightness: 0.3)
        XCTAssertEqual(curve.points.map(\.lux), [0, 10, 50, 500, 2000])
        for lux in [3.0, 30, 300, 3000, 7, 70, 700, 7000, 1] {
            curve.learn(lux: lux, brightness: min(1, log10(lux + 1) / 4))
            XCTAssertLessThanOrEqual(curve.points.count, 5)
            XCTAssertEqual(curve.value(at: lux), min(1, log10(lux + 1) / 4), accuracy: 0.0001)
        }
    }

    func testStoredCurveWithManyPointsIsTrimmedToFive() throws {
        let points = [0.0, 5, 10, 20, 100, 120, 500, 2000].enumerated().map { "{\"lux\":\($1),\"brightness\":\(Double($0) / 7)}" }
        let json = "{\"isCalibrated\":true,\"points\":[\(points.joined(separator: ","))]}"
        let curve = try JSONDecoder().decode(BrightnessCurve.self, from: Data(json.utf8))
        XCTAssertEqual(curve.points.count, 5)
        XCTAssertEqual(curve.points.first?.lux, 0)
        XCTAssertEqual(curve.points.last?.lux, 2000)
        XCTAssertTrue(curve.isCalibrated)
    }
}
