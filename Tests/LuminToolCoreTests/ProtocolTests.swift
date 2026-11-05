import XCTest
@testable import LuminToolCore

final class ProtocolTests: XCTestCase {
    func testEndpointRejectsCredentialsQueriesAndNonHTTP() throws {
        for url in ["file:///tmp/a", "http://user:secret@host", "http://host/?token=x", "http://host/#x", "bad"] {
            XCTAssertThrowsError(try HomeAssistantEndpoint(url))
        }
        let endpoint = try HomeAssistantEndpoint(" http://homeassistant.local:8123/ ")
        XCTAssertEqual(endpoint.base.absoluteString, "http://homeassistant.local:8123")
        XCTAssertEqual(endpoint.webSocket.absoluteString, "ws://homeassistant.local:8123/api/websocket")
        XCTAssertEqual(try HomeAssistantEndpoint("https://host/ha/").webSocket.absoluteString, "wss://host/ha/api/websocket")
    }

    func testLuxOnlyAcceptsValidIlluminance() {
        XCTAssertEqual(Illuminance.value("0", unit: "lx"), 0)
        XCTAssertEqual(Illuminance.value("150.5", unit: "lux"), 150.5)
        for text in ["unknown", "unavailable", "-1", "nan", "inf"] {
            XCTAssertNil(Illuminance.value(text, unit: "lx"))
        }
        XCTAssertNil(Illuminance.value("5", unit: "W"))
    }

    func testOnlySensorIsPickedWhenNoneSelected() {
        XCTAssertEqual(SensorChoice.entity(selected: "", available: ["sensor.a"]), "sensor.a")
        XCTAssertEqual(SensorChoice.entity(selected: "", available: ["sensor.a", "sensor.b"]), "")
        XCTAssertEqual(SensorChoice.entity(selected: "", available: []), "")
        XCTAssertEqual(SensorChoice.entity(selected: "sensor.b", available: ["sensor.a"]), "sensor.b")
    }

    func testLanguageMapsToAppleLanguages() {
        XCTAssertNil(AppLanguage.system.appleLanguages)
        XCTAssertEqual(AppLanguage.english.appleLanguages, ["en"])
        XCTAssertEqual(AppLanguage.russian.appleLanguages, ["ru"])
        XCTAssertEqual(AppLanguage(appleLanguages: nil), .system)
        XCTAssertEqual(AppLanguage(appleLanguages: ["en"]), .english)
        XCTAssertEqual(AppLanguage(appleLanguages: ["ru-RU"]), .russian)
        XCTAssertEqual(AppLanguage(appleLanguages: ["de"]), .system)
    }

    func testCorruptCurveIsRejected() {
        let json = #"{"points":[{"lux":10,"brightness":0.5},{"lux":0,"brightness":0.2}],"isCalibrated":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BrightnessCurve.self, from: Data(json.utf8)))
    }
}
