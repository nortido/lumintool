import XCTest
@testable import LuminToolCore

final class SettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    }

    func testOldConfigurationKeepsHomeAssistantSettings() throws {
        let config = try decode(#"{"server":"http://ha.lan:8123","entity":"sensor.lux","monitor":"ABCD","enabled":false}"#)
        XCTAssertEqual(config.server, "http://ha.lan:8123")
        XCTAssertEqual(config.entity, "sensor.lux")
        XCTAssertEqual(config.monitor, "ABCD")
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.source, .homeAssistant)
    }

    func testUnknownSourceFallsBackToHomeAssistant() throws {
        let config = try decode(#"{"server":"http://ha.lan:8123","entity":"sensor.lux","monitor":"ABCD","enabled":false,"source":"zigbee"}"#)
        XCTAssertEqual(config.source, .homeAssistant)
        XCTAssertEqual(config.server, "http://ha.lan:8123")
        XCTAssertEqual(config.entity, "sensor.lux")
        XCTAssertEqual(config.monitor, "ABCD")
        XCTAssertFalse(config.enabled)
    }

    func testSourceSettingsSurviveEncodeAndDecode() throws {
        var config = Configuration()
        config.source = .mqtt
        config.mqtt.broker = "mqtt://broker.lan"
        config.mqtt.topic = "z2m/lux"
        config.serial.port = "/dev/cu.usbmodem1"
        config.serial.baud = 9600
        config.esphome.address = "sensor.local"
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.source, .mqtt)
        XCTAssertEqual(decoded.mqtt.broker, "mqtt://broker.lan")
        XCTAssertEqual(decoded.mqtt.topic, "z2m/lux")
        XCTAssertEqual(decoded.serial.port, "/dev/cu.usbmodem1")
        XCTAssertEqual(decoded.serial.baud, 9600)
        XCTAssertEqual(decoded.esphome.address, "sensor.local")
    }

    func testHomeAssistantCurveKeyIsUnchanged() {
        var config = Configuration()
        config.server = "http://homeassistant.local:8123"
        config.entity = "sensor.lux"
        config.monitor = "ABCD-1234"
        XCTAssertEqual(config.curveKey, "curve.WyJodHRwOlwvXC9ob21lYXNzaXN0YW50LmxvY2FsOjgxMjMiLCJzZW5zb3IubHV4IiwiQUJDRC0xMjM0Il0=")
    }

    func testCurveKeysSeparateSources() {
        var config = Configuration()
        config.monitor = "ABCD-1234"
        config.mqtt.broker = "mqtt://broker.lan"
        config.mqtt.topic = "z2m/lux"
        config.serial.port = "/dev/cu.usbmodem1"
        config.esphome.address = "sensor.local"
        config.esphome.sensor = "illuminance"
        var keys: [SourceKind: String] = [:]
        for kind in [SourceKind.homeAssistant, .mqtt, .serial, .esphome] {
            config.source = kind
            keys[kind] = config.curveKey
        }
        XCTAssertEqual(Set(keys.values).count, 4)
        XCTAssertTrue(keys[.mqtt]!.hasPrefix("curve.mqtt."))

        config.source = .mqtt
        config.mqtt.topic = "z2m/other"
        XCTAssertNotEqual(config.curveKey, keys[.mqtt])
        config.mqtt.topic = "z2m/lux"
        config.mqtt.username = "user"
        XCTAssertEqual(config.curveKey, keys[.mqtt])

        config.source = .serial
        config.serial.baud = 9600
        XCTAssertEqual(config.curveKey, keys[.serial])
    }

    func testHasSensorPerSource() {
        var config = Configuration()
        XCTAssertFalse(config.hasSensor)
        config.entity = "sensor.lux"
        XCTAssertTrue(config.hasSensor)

        config.source = .mqtt
        config.mqtt.broker = "mqtt://broker.lan"
        XCTAssertFalse(config.hasSensor)
        config.mqtt.topic = "z2m/lux"
        XCTAssertTrue(config.hasSensor)

        config.source = .serial
        XCTAssertFalse(config.hasSensor)
        config.serial.port = "/dev/cu.usbmodem1"
        XCTAssertTrue(config.hasSensor)

        config.source = .esphome
        config.esphome.address = "sensor.local"
        XCTAssertFalse(config.hasSensor)
        config.esphome.sensor = "illuminance"
        XCTAssertTrue(config.hasSensor)
    }

    func testCheckUpdatesSurvivesDecode() throws {
        XCTAssertFalse(try decode(#"{"checkUpdates":false}"#).checkUpdates)
        var config = Configuration()
        config.checkUpdates = false
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(decoded.checkUpdates)
    }

    func testOldConfigurationChecksUpdates() throws {
        let config = try decode(#"{"server":"http://ha.lan:8123","entity":"sensor.lux","monitor":"ABCD","enabled":false}"#)
        XCTAssertTrue(config.checkUpdates)
        XCTAssertEqual(config.server, "http://ha.lan:8123")
        XCTAssertEqual(config.entity, "sensor.lux")
        XCTAssertEqual(config.monitor, "ABCD")
        XCTAssertFalse(config.enabled)
    }

    func testInvalidCheckUpdatesKeepsOtherFields() throws {
        let config = try decode(#"{"server":"http://ha.lan:8123","checkUpdates":"no"}"#)
        XCTAssertTrue(config.checkUpdates)
        XCTAssertEqual(config.server, "http://ha.lan:8123")
    }
}
