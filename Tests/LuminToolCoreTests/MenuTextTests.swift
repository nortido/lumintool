import XCTest
@testable import LuminToolCore

final class MenuTextTests: XCTestCase {
    func testShortTextStaysOnOneLine() {
        XCTAssertEqual(MenuText.wrap("Illuminance: 4.0 lx"), "Illuminance: 4.0 lx")
    }

    func testLinesAreBalanced() {
        XCTAssertEqual(MenuText.wrap("Не удалось установить обновление."), "Не удалось установить\nобновление.")
        XCTAssertEqual(MenuText.wrap("macOS does not allow brightness control."), "macOS does not allow\nbrightness control.")
        XCTAssertEqual(MenuText.wrap("Restart LuminTool for version 1.5.1"), "Restart LuminTool\nfor version 1.5.1")
    }

    func testBreaksAfterPunctuation() {
        XCTAssertEqual(MenuText.wrap("Too many requests to GitHub. Try again later."), "Too many requests to GitHub.\nTry again later.")
        XCTAssertEqual(MenuText.wrap("Waiting for the sensor; brightness kept"), "Waiting for the sensor;\nbrightness kept")
        XCTAssertEqual(MenuText.wrap("Ожидание датчика; яркость сохранена"), "Ожидание датчика;\nяркость сохранена")
    }

    func testShortWordDoesNotEndALine() {
        XCTAssertEqual(MenuText.wrap("Перезапустите LuminTool для версии 1.5.1"), "Перезапустите LuminTool\nдля версии 1.5.1")
        XCTAssertEqual(MenuText.wrap("aaaaaaaa в bbbbbbbb ccccccc", width: 19), "aaaaaaaa\nв bbbbbbbb ccccccc")
    }

    func testEveryLineFitsTheWidth() {
        let texts = [
            "macOS не даёт менять яркость монитора.",
            "Too many requests to GitHub. Try again later.",
            "Укажите адрес устройства, например sensor.local или http://192.168.1.20, без пути, логина и параметров."
        ]
        for text in texts {
            let lines = MenuText.wrap(text).components(separatedBy: "\n")
            XCTAssertTrue(lines.allSatisfy { $0.count <= 30 }, "\(lines)")
            XCTAssertEqual(lines.joined(separator: " "), text)
        }
    }

    func testMenuTitleDropsPeriodAtLineEnd() {
        XCTAssertEqual(MenuText.title("macOS does not allow brightness control."), "macOS does not allow\nbrightness control")
        XCTAssertEqual(MenuText.title("Too many requests to GitHub. Try again later."), "Too many requests to GitHub\nTry again later")
        XCTAssertEqual(MenuText.title("Version 1.5.1 is ready."), "Version 1.5.1 is ready")
        XCTAssertEqual(MenuText.title("Checking the monitor\u{2026}"), "Checking the monitor\u{2026}")
    }

    func testLongWordIsKeptWhole() {
        let word = String(repeating: "x", count: 40)
        XCTAssertEqual(MenuText.wrap("a \(word) b"), "a\n\(word)\nb")
    }
}
