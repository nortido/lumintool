import XCTest
@testable import LuminToolCore

final class MQTTTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func publish(_ header: UInt8, topic: String, extra: [UInt8] = [], payload: String) -> Data {
        let topicBytes = Array(topic.utf8)
        let body = [UInt8(topicBytes.count >> 8), UInt8(topicBytes.count & 0xFF)] + topicBytes + extra + Array(payload.utf8)
        return Data([header] + MQTT.remainingLength(body.count) + body)
    }

    func testRemainingLengthSpecExamples() {
        XCTAssertEqual(MQTT.remainingLength(0), [0x00])
        XCTAssertEqual(MQTT.remainingLength(64), [0x40])
        XCTAssertEqual(MQTT.remainingLength(127), [0x7F])
        XCTAssertEqual(MQTT.remainingLength(128), [0x80, 0x01])
        XCTAssertEqual(MQTT.remainingLength(321), [0xC1, 0x02])
        XCTAssertEqual(MQTT.remainingLength(268_435_455), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    func testConnectBytes() {
        XCTAssertEqual(hex(MQTT.connect(clientID: "LuminTool-1", username: "u", password: "p", keepAlive: 30)),
                       "10 1D 00 04 4D 51 54 54 04 C2 00 1E 00 0B 4C 75 6D 69 6E 54 6F 6F 6C 2D 31 00 01 75 00 01 70")
        let anonymous = "10 17 00 04 4D 51 54 54 04 02 00 1E 00 0B 4C 75 6D 69 6E 54 6F 6F 6C 2D 31"
        XCTAssertEqual(hex(MQTT.connect(clientID: "LuminTool-1", username: nil, password: nil, keepAlive: 30)), anonymous)
        XCTAssertEqual(hex(MQTT.connect(clientID: "LuminTool-1", username: nil, password: "p", keepAlive: 30)), anonymous)
        XCTAssertEqual(hex(MQTT.connect(clientID: "LuminTool-1", username: "", password: "p", keepAlive: 30)), anonymous)
    }

    func testSubscribeBytes() {
        XCTAssertEqual(hex(MQTT.subscribe(packetID: 1, topic: "a/b")), "82 08 00 01 00 03 61 2F 62 00")
        XCTAssertEqual(hex(MQTT.pingRequest), "C0 00")
    }

    func testFramerSplitAndCoalesced() throws {
        let stream = Data([0x20, 0x02, 0x00, 0x00]) + publish(0x31, topic: "a/b", payload: "42") + Data([0xD0, 0x00, 0x40, 0x02, 0x00, 0x01])
        let expected: [MQTTPacket] = [.connAck(0), .publish("a/b", Data("42".utf8)), .pingResp, .other(4)]
        var whole = MQTTFrameReader()
        XCTAssertEqual(try whole.append(stream), expected)
        var bytewise = MQTTFrameReader()
        var packets: [MQTTPacket] = []
        for byte in stream { packets += try bytewise.append(Data([byte])) }
        XCTAssertEqual(packets, expected)
    }

    func testPublishQoS0AndQoS1() throws {
        var reader = MQTTFrameReader()
        XCTAssertEqual(try reader.append(publish(0x31, topic: "a/b", payload: "42")), [.publish("a/b", Data("42".utf8))])
        XCTAssertEqual(try reader.append(publish(0x32, topic: "a/b", extra: [0x00, 0x0A], payload: "42")), [.publish("a/b", Data("42".utf8))])
    }

    func testConnAckSubAck() throws {
        var reader = MQTTFrameReader()
        XCTAssertEqual(try reader.append(Data([0x20, 0x02, 0x00, 0x05])), [.connAck(5)])
        XCTAssertEqual(try reader.append(Data([0x90, 0x03, 0x00, 0x01, 0x80])), [.subAck(1, [0x80])])
    }

    func testMalformedThrows() {
        for bytes: [UInt8] in [[0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], [0x30, 0x81, 0x80, 0x40], [0x30, 0x03, 0x00, 0x05, 0x61]] {
            var reader = MQTTFrameReader()
            XCTAssertThrowsError(try reader.append(Data(bytes)), "\(bytes)")
        }
    }

    func testEndpoint() throws {
        let plain = try MQTTEndpoint("192.168.1.10")
        XCTAssertEqual([plain.host, String(plain.port), String(plain.tls)], ["192.168.1.10", "1883", "false"])
        let secure = try MQTTEndpoint(" mqtts://broker.lan/ ")
        XCTAssertEqual([secure.host, String(secure.port), String(secure.tls)], ["broker.lan", "8883", "true"])
        let custom = try MQTTEndpoint("mqtt://h:1884")
        XCTAssertEqual([custom.host, String(custom.port), String(custom.tls)], ["h", "1884", "false"])
        XCTAssertEqual(custom.address, "mqtt://h:1884")
        XCTAssertEqual(plain.address, "mqtt://192.168.1.10:1883")
        let v6 = try MQTTEndpoint("mqtt://[::1]:1883")
        XCTAssertEqual([v6.host, String(v6.port), v6.address], ["::1", "1883", "mqtt://[::1]:1883"])
        for endpoint in [plain, secure, custom, v6, try MQTTEndpoint("broker.lan"), try MQTTEndpoint("mqtts://10.0.0.2")] {
            let again = try MQTTEndpoint(endpoint.address)
            XCTAssertEqual([again.host, String(again.port), again.address], [endpoint.host, String(endpoint.port), endpoint.address])
        }
        for text in ["mqtt://u:p@h", "http://h", "mqtt://h/x", "mqtt://h?x", "", "mqtt://h:0", "mqtt://h:65536", "mqtt://h#x"] {
            XCTAssertThrowsError(try MQTTEndpoint(text), text)
        }
    }

    func testTopic() throws {
        XCTAssertEqual(try MQTTTopic.validated(" z2m/lux "), "z2m/lux")
        for text in ["", "  ", "a/+", "a/#", "a\u{0}b"] {
            XCTAssertThrowsError(try MQTTTopic.validated(text), text)
        }
    }

    func testPayloadLux() {
        func lux(_ text: String, _ keyPath: String = "") -> Double? { PayloadLux.value(Data(text.utf8), keyPath: keyPath) }
        XCTAssertEqual(lux("123.4"), 123.4)
        XCTAssertEqual(lux(" 5\n"), 5)
        XCTAssertEqual(lux(#"{"illuminance":40}"#), 40)
        XCTAssertEqual(lux(#"{"illuminance":40,"illuminance_lux":12}"#), 12)
        XCTAssertEqual(lux(#"{"Time":"t","BH1750":{"Illuminance":79}}"#), 79)
        XCTAssertEqual(lux(#"{"Time":"t","BH1750":{"Illuminance":79}}"#, "BH1750.Illuminance"), 79)
        XCTAssertEqual(lux(#"{"a":{"b":"7"}}"#, "a.b"), 7)
        for text in ["", "nan", "-1", "0x10", "unavailable", #"{"illuminance":null}"#, #"{"illuminance":-3}"#, #"{"illuminance":true}"#,
                     #"{"a":{"Illuminance":1},"b":{"Illuminance":2}}"#, #"{"temperature":3}"#, "{bad"] {
            XCTAssertNil(lux(text), text)
        }
        XCTAssertNil(lux(#"{"a":{"b":1}}"#, "a.c"))
        XCTAssertNil(lux("5", "a"))
    }
}
