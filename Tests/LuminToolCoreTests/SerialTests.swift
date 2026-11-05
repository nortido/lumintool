import XCTest
@testable import LuminToolCore

final class SerialTests: XCTestCase {
    func testLineBuffer() {
        var buffer = LineBuffer(maxLength: 256)
        XCTAssertEqual(buffer.append(Array("12\r\n3".utf8)), ["12"])
        XCTAssertEqual(buffer.append(Array("4\n".utf8)), ["34"])
        XCTAssertEqual(buffer.append(Array("\n".utf8)), [""])
        XCTAssertEqual(buffer.append(Data(repeating: 0x78, count: 300)), [])
        XCTAssertEqual(buffer.append(Array("5\n".utf8)), [])
        XCTAssertEqual(buffer.append(Array("6\n".utf8)), ["6"])
        XCTAssertEqual(buffer.append(Array("a\nb\n".utf8)), ["a", "b"])
    }

    func testLineBufferDropsLongCompleteLine() {
        var buffer = LineBuffer(maxLength: 256)
        let long = Array(repeating: UInt8(0x78), count: 300) + [0x0A] + Array("7\n".utf8)
        XCTAssertEqual(buffer.append(long), ["7"])
    }

    func testLineBufferDiscardsOversizeTailAcrossChunks() {
        var buffer = LineBuffer(maxLength: 256)
        XCTAssertEqual(buffer.append(Data(repeating: 0x78, count: 200)), [])
        XCTAssertEqual(buffer.append(Data(repeating: 0x78, count: 100)), [])
        XCTAssertEqual(buffer.append(Array("21.5\n".utf8)), [])
        XCTAssertEqual(buffer.append(Array("7\n".utf8)), ["7"])
    }

    func testSerialLine() {
        XCTAssertEqual(SerialLine.parse("123.4"), .lux(123.4))
        XCTAssertEqual(SerialLine.parse("45.83"), .lux(45.83))
        XCTAssertEqual(SerialLine.parse("Lux: 12"), .lux(12))
        XCTAssertEqual(SerialLine.parse("lux=7.5 lx"), .lux(7.5))
        XCTAssertEqual(SerialLine.parse("300 lux"), .lux(300))
        XCTAssertEqual(SerialLine.parse("nan"), .unavailable)
        XCTAssertEqual(SerialLine.parse("Lux: -1"), .unavailable)
        XCTAssertEqual(SerialLine.parse("inf"), .unavailable)
        XCTAssertEqual(SerialLine.parse("BH1750: 12 lx"), .lux(12))
        XCTAssertEqual(SerialLine.parse("Light: 300"), .lux(300))
        XCTAssertEqual(SerialLine.parse("ILLUMINANCE = 7"), .lux(7))
        for text in ["Temperature: 23.5", "Humidity=40"] {
            XCTAssertEqual(SerialLine.parse(text), .ignored, text)
        }
        for text in ["BH1750 ready", "[D][sensor:094]: 'L': Sending state 1 lx", "", "12.5.3", "1e3"] {
            XCTAssertEqual(SerialLine.parse(text), .ignored, text)
        }
    }

    func testPortCandidates() {
        let names = ["cu.usbserial-10", "tty.usbserial-10", "cu.Bluetooth-Incoming-Port", "cu.debug-console", "cu.usbmodem1", "null"]
        XCTAssertEqual(SerialPorts.candidates(names), ["/dev/cu.usbmodem1", "/dev/cu.usbserial-10"])
    }
}
