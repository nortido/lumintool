import XCTest
@testable import LuminToolCore

final class ESPHomeTests: XCTestCase {
    func testSSE() {
        var parser = SSEParser()
        XCTAssertNil(parser.line("event: state"))
        XCTAssertNil(parser.line("data: {..}"))
        XCTAssertEqual(parser.line(""), SSEEvent(name: "state", data: "{..}"))

        XCTAssertNil(parser.line("data: a"))
        XCTAssertNil(parser.line("data: b"))
        XCTAssertEqual(parser.line(""), SSEEvent(name: "message", data: "a\nb"))

        XCTAssertNil(parser.line("data:x"))
        XCTAssertEqual(parser.line(""), SSEEvent(name: "message", data: "x"))

        for line in [": comment", "id: 5", "retry: 1000"] { XCTAssertNil(parser.line(line)) }
        XCTAssertNil(parser.line(""))

        XCTAssertNil(parser.line("event: ping"))
        XCTAssertNil(parser.line(""))
        XCTAssertNil(parser.line("data: y"))
        XCTAssertEqual(parser.line(""), SSEEvent(name: "message", data: "y"))
    }

    func testSSEDropsOversizeEvent() {
        var parser = SSEParser()
        let chunk = String(repeating: "x", count: 60_000)
        for _ in 0..<8 { XCTAssertNil(parser.line("data: " + chunk)) }
        XCTAssertNil(parser.line(""))
        XCTAssertNil(parser.line("event: state"))
        XCTAssertNil(parser.line("data: x"))
        XCTAssertEqual(parser.line(""), SSEEvent(name: "state", data: "x"))
    }

    func testESPHomeState() {
        let current = ESPHomeState.parse(#"{"id":"sensor/Illuminance","state":"12.5 lx","value":12.5}"#)
        XCTAssertEqual(current?.key, "sensor/Illuminance")
        XCTAssertEqual(current?.name, "Illuminance")
        XCTAssertEqual(current?.isLux, true)
        XCTAssertEqual(current?.value, 12.5)

        let legacy = ESPHomeState.parse(#"{"id":"sensor-illuminance","state":"12.5 lx","value":12.5}"#)
        XCTAssertEqual(legacy?.key, "sensor-illuminance")
        XCTAssertEqual(legacy?.name, "illuminance")
        XCTAssertEqual(ESPHomeState.parse(#"{"name_id":"sensor/Illuminance","id":"sensor-illuminance","state":"3 lx","value":3}"#)?.key, "sensor/Illuminance")
        XCTAssertEqual(ESPHomeState.parse(#"{"name_id":"sensor/Illuminance","id":"sensor-illuminance","state":"3 lx","value":3}"#)?.name, "Illuminance")

        let temperature = ESPHomeState.parse(#"{"id":"sensor/Outside Temperature","state":"19.8 °C","value":19.8}"#)
        XCTAssertEqual(temperature?.key, "sensor/Outside Temperature")
        XCTAssertEqual(temperature?.isLux, false)
        XCTAssertEqual(temperature?.value, 19.8)

        let device = ESPHomeState.parse(#"{"id":"sensor/Dev/Lux Level","state":"7 lux","value":7}"#)
        XCTAssertEqual(device?.key, "sensor/Dev/Lux Level")
        XCTAssertEqual(device?.name, "Dev/Lux Level")
        XCTAssertEqual(device?.isLux, true)
        let light = ESPHomeState.parse(#"{"id":"sensor/Свет","state":"1 lx","value":1}"#)
        let shade = ESPHomeState.parse(#"{"id":"sensor/Тень","state":"1 lx","value":1}"#)
        XCTAssertEqual(light?.key, "sensor/Свет")
        XCTAssertNotEqual(light?.key, shade?.key)
        XCTAssertNil(ESPHomeState.parse(#"{"id":"binary_sensor/x","state":"ON","value":true}"#))
        XCTAssertNil(ESPHomeState.parse("not json"))

        for json in [#"{"id":"sensor/Illuminance","state":"NA","value":NaN}"#,
                     #"{"id":"sensor/Illuminance","state":"NA"}"#,
                     #"{"id":"sensor/Illuminance","state":"NA","value":null}"#,
                     #"{"id":"sensor/Illuminance","state":"-1 lx","value":-1}"#,
                     #"{"id":"sensor/Illuminance","state":"x lx","value":"12"}"#] {
            let state = ESPHomeState.parse(json)
            XCTAssertEqual(state?.key, "sensor/Illuminance", json)
            XCTAssertNil(state?.value, json)
        }
    }

    func testESPHomeEndpoint() throws {
        let bare = try ESPHomeEndpoint("sensor.local")
        XCTAssertEqual(bare.base.absoluteString, "http://sensor.local")
        XCTAssertEqual(bare.events.absoluteString, "http://sensor.local/events")
        XCTAssertEqual(bare.address, "http://sensor.local")
        let port = try ESPHomeEndpoint(" http://10.0.0.5:8080/ ")
        XCTAssertEqual(port.address, "http://10.0.0.5:8080")
        XCTAssertEqual(port.events.absoluteString, "http://10.0.0.5:8080/events")
        XCTAssertEqual(try ESPHomeEndpoint("https://h").events.absoluteString, "https://h/events")
        for bad in ["http://u:p@h", "http://h?x", "http://h/x", "http://h#x", "ftp://h", "", "http://h:0", "http://"] {
            XCTAssertThrowsError(try ESPHomeEndpoint(bad), bad)
        }
    }
}
