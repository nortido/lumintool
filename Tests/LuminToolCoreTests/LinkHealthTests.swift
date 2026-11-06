import XCTest
@testable import LuminToolCore

final class LinkHealthTests: XCTestCase {
    func testDelayedWatchdogPingsInsteadOfTimingOut() {
        var watchdog = LinkWatchdog(now: 0)
        watchdog.ready(now: 1)
        XCTAssertEqual(watchdog.tick(now: 5), .wait)
        XCTAssertEqual(watchdog.tick(now: 80), .ping)
        watchdog.received(now: 80.2)
        XCTAssertEqual(watchdog.tick(now: 85), .wait)
        XCTAssertEqual(watchdog.tick(now: 160), .ping)
    }

    func testUnansweredPingTimesOut() {
        var watchdog = LinkWatchdog(now: 0)
        watchdog.ready(now: 1)
        XCTAssertEqual(watchdog.tick(now: 16), .ping)
        XCTAssertEqual(watchdog.tick(now: 31), .ping)
        XCTAssertEqual(watchdog.tick(now: 37), .timeout)
    }

    func testPingsOnScheduleEvenWhileReceiving() {
        var watchdog = LinkWatchdog(now: 0)
        watchdog.ready(now: 0)
        for second in stride(from: 1.0, to: 15, by: 1) {
            watchdog.received(now: second)
            XCTAssertEqual(watchdog.tick(now: second), .wait)
        }
        XCTAssertEqual(watchdog.tick(now: 15), .ping)
    }

    func testConnectTimeout() {
        var watchdog = LinkWatchdog(now: 0)
        XCTAssertEqual(watchdog.tick(now: 20), .wait)
        XCTAssertEqual(watchdog.tick(now: 21), .timeout)
    }

    func testShortOutageKeepsLastValue() {
        var grace = OutageGrace()
        XCTAssertFalse(grace.lost(now: 100))
        XCTAssertFalse(grace.lost(now: 150))
        grace.restored()
        XCTAssertFalse(grace.lost(now: 300))
        XCTAssertFalse(grace.lost(now: 360))
        XCTAssertTrue(grace.lost(now: 361))
        XCTAssertTrue(grace.lost(now: 400))
    }
}
