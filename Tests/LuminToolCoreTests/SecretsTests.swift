import Foundation
import Security
import XCTest
@testable import LuminToolCore

final class SecretsTests: XCTestCase {
    private static let ha = "local.nortido.LuminTool.homeassistant"
    private static let mqtt = "local.nortido.LuminTool.mqtt"
    private static let esphome = "local.nortido.LuminTool.esphome"
    private var root: URL!
    private var directory: URL!

    private final class FakeLegacy: LegacySecrets {
        var answer: LegacySecret
        var failOnRead = false
        var onDelete: (() -> Void)?
        private(set) var reads: [[String]] = []
        private(set) var deletes: [[String]] = []

        init(_ answer: LegacySecret) { self.answer = answer }

        func read(service: String, account: String) -> LegacySecret {
            if failOnRead { XCTFail("unexpected legacy read") }
            reads.append([service, account])
            return answer
        }

        func delete(service: String, account: String) {
            deletes.append([service, account])
            onDelete?()
        }
    }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsTests-\(UUID().uuidString)")
        directory = root.appendingPathComponent("LuminTool")
    }

    override func tearDown() {
        for dir in [directory!, root!] { chmod(dir.path, 0o700) }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeDirectory(_ dir: URL, mode: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func entries(_ store: SecretStore) throws -> [SecretEntry] {
        try JSONDecoder().decode(SecretFile.self, from: Data(contentsOf: store.file)).entries
    }

    private func writeFile(_ text: String, to url: URL, mode: Int = 0o600) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func assertMessage(_ expression: @autoclosure () throws -> Any?, _ text: String, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { XCTAssertEqual($0.localizedDescription, text, line: line) }
    }

    func testLegacyStatusMapping() {
        XCTAssertEqual(LegacySecret(status: errSecSuccess, data: Data("pw".utf8)), .found("pw"))
        XCTAssertEqual(LegacySecret(status: errSecItemNotFound, data: nil), .absent)
        XCTAssertEqual(LegacySecret(status: errSecUserCanceled, data: nil), .declined)
        XCTAssertEqual(LegacySecret(status: errSecAuthFailed, data: nil), .declined)
        XCTAssertEqual(LegacySecret(status: errSecInteractionNotAllowed, data: nil), .failed(-25308))
        XCTAssertEqual(LegacySecret(status: errSecSuccess, data: Data([0xff])), .failed(0))
        XCTAssertEqual(LegacySecret(status: errSecSuccess, data: nil), .failed(0))
    }

    func testSaveCreatesPrivateFiles() throws {
        let store = SecretStore(directory: directory)
        try store.save("pw", service: Self.mqtt, account: "mqtt://b:1883|u")
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(store.file), 0o600)
        XCTAssertEqual(try entries(store), [SecretEntry(service: Self.mqtt, account: "mqtt://b:1883|u", secret: "pw")])

        let other = SecretStore(directory: root.appendingPathComponent("Open"))
        try makeDirectory(other.directory, mode: 0o755)
        try other.save("pw", service: Self.mqtt, account: "u")
        XCTAssertEqual(try mode(other.directory), 0o700)
        XCTAssertEqual(try mode(other.file), 0o600)
    }

    func testSaveKeepsOtherEntries() throws {
        let store = SecretStore(directory: directory)
        try store.save("token", service: Self.ha, account: "http://ha.lan:8123/")
        try store.save("mqtt-pw", service: Self.mqtt, account: "b|u")
        try store.save("esp-pw", service: Self.esphome, account: "b|u")
        try store.save("token2", service: Self.ha, account: "http://ha.lan:8123/")
        XCTAssertEqual(try entries(store).count, 3)
        let legacy = FakeLegacy(.absent)
        XCTAssertEqual(try store.secret(service: Self.ha, account: "http://ha.lan:8123/", legacy: legacy), "token2")
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "mqtt-pw")
        XCTAssertEqual(try store.secret(service: Self.esphome, account: "b|u", legacy: legacy), "esp-pw")
        XCTAssertEqual(legacy.reads.count, 0)
    }

    func testNoTempFilesLeft() throws {
        let store = SecretStore(directory: directory)
        for value in ["a", "b", "c"] { try store.save(value, service: Self.mqtt, account: value) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [SecretStore.fileName])
    }

    func testMigrationMovesKeychainSecret() throws {
        let store = SecretStore(directory: directory)
        let legacy = FakeLegacy(.found("pw"))
        var seenInDelete: String?
        legacy.onDelete = {
            let onDisk = FakeLegacy(.absent)
            onDisk.failOnRead = true
            seenInDelete = try? SecretStore(directory: self.directory).secret(service: Self.mqtt, account: "b|u", legacy: onDisk)
        }
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "pw")
        XCTAssertEqual(legacy.reads, [[Self.mqtt, "b|u"]])
        XCTAssertEqual(legacy.deletes, [[Self.mqtt, "b|u"]])
        XCTAssertEqual(seenInDelete, "pw")
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "pw")
        XCTAssertEqual(try SecretStore(directory: directory).secret(service: Self.mqtt, account: "b|u", legacy: legacy), "pw")
        XCTAssertEqual(legacy.reads.count, 1)
        XCTAssertEqual(try mode(store.file), 0o600)
    }

    func testMigrationSkipsDeleteWhenVerifyFails() throws {
        var store = SecretStore(directory: directory)
        let legacy = FakeLegacy(.found("pw"))
        let other = try JSONEncoder().encode(SecretFile(entries: [SecretEntry(service: Self.mqtt, account: "b|u", secret: "other")]))
        store.beforeVerify = { do { try other.write(to: store.file) } catch { XCTFail("\(error)") } }
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "pw")
        XCTAssertEqual(legacy.deletes.count, 0)
        XCTAssertEqual(try Data(contentsOf: store.file), other)

        var gone = SecretStore(directory: root.appendingPathComponent("Gone"))
        let second = FakeLegacy(.found("pw"))
        gone.beforeVerify = { do { try FileManager.default.removeItem(at: gone.file) } catch { XCTFail("\(error)") } }
        XCTAssertEqual(try gone.secret(service: Self.mqtt, account: "b|u", legacy: second), "pw")
        XCTAssertEqual(second.deletes.count, 0)
        gone.beforeVerify = nil
        XCTAssertEqual(try gone.secret(service: Self.mqtt, account: "b|u", legacy: second), "pw")
        XCTAssertEqual(second.reads.count, 2)
    }

    func testMigrationRecordsAbsent() throws {
        let store = SecretStore(directory: directory)
        let legacy = FakeLegacy(.absent)
        XCTAssertNil(try store.secret(service: Self.ha, account: "http://ha.lan:8123/", legacy: legacy))
        XCTAssertEqual(try entries(store), [SecretEntry(service: Self.ha, account: "http://ha.lan:8123/", secret: nil)])
        XCTAssertNil(try store.secret(service: Self.ha, account: "http://ha.lan:8123/", legacy: legacy))
        XCTAssertEqual(legacy.reads.count, 1)
        XCTAssertEqual(legacy.deletes.count, 0)
        try store.save("token", service: Self.ha, account: "http://ha.lan:8123/")
        XCTAssertEqual(try store.secret(service: Self.ha, account: "http://ha.lan:8123/", legacy: legacy), "token")
        XCTAssertEqual(legacy.reads.count, 1)
    }

    func testMigrationRecordsDecline() throws {
        let store = SecretStore(directory: directory)
        let legacy = FakeLegacy(.declined)
        XCTAssertNil(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy))
        XCTAssertEqual(legacy.deletes.count, 0)
        XCTAssertNil(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy))
        XCTAssertEqual(legacy.reads.count, 1)
    }

    func testMigrationFailureRetries() throws {
        let store = SecretStore(directory: directory)
        let legacy = FakeLegacy(.failed(-25308))
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not read the token from Keychain (-25308).")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not read the token from Keychain (-25308).")
        XCTAssertEqual(legacy.reads.count, 2)
    }

    func testMigrationKeepsKeychainWhenWriteFails() throws {
        let store = SecretStore(directory: directory)
        try makeDirectory(directory, mode: 0o500)
        let legacy = FakeLegacy(.found("pw"))
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not save the token (13).")
        XCTAssertEqual(legacy.deletes.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }

    func testCorruptFileIsKept() throws {
        let store = SecretStore(directory: directory)
        try makeDirectory(directory, mode: 0o700)
        try writeFile("not json", to: store.file)
        let legacy = FakeLegacy(.found("pw"))
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not read the file with saved passwords.")
        assertMessage(try store.save("pw", service: Self.mqtt, account: "b|u"), "Could not read the file with saved passwords.")
        XCTAssertEqual(legacy.reads.count, 0)
        XCTAssertEqual(try Data(contentsOf: store.file), Data("not json".utf8))
    }

    func testUnsafeFilesRefused() throws {
        let store = SecretStore(directory: directory)
        try makeDirectory(directory, mode: 0o700)
        let target = root.appendingPathComponent("elsewhere.json")
        let valid = #"{"entries":[{"service":"local.nortido.LuminTool.mqtt","account":"b|u","secret":"pw"}]}"#
        try writeFile(valid, to: target)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        let legacy = FakeLegacy(.found("pw"))
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not read the file with saved passwords.")
        assertMessage(try store.save("new", service: Self.mqtt, account: "b|u"), "Could not read the file with saved passwords.")
        XCTAssertEqual(try Data(contentsOf: target), Data(valid.utf8))

        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: false)
        assertMessage(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "Could not read the file with saved passwords.")
        XCTAssertEqual(legacy.reads.count, 0)
    }

    func testReadFixesFileMode() throws {
        let store = SecretStore(directory: directory)
        try makeDirectory(directory, mode: 0o700)
        try writeFile(#"{"entries":[{"service":"local.nortido.LuminTool.mqtt","account":"b|u","secret":"pw"}]}"#, to: store.file, mode: 0o644)
        let legacy = FakeLegacy(.absent)
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "b|u", legacy: legacy), "pw")
        XCTAssertEqual(try mode(store.file), 0o600)
        XCTAssertEqual(legacy.reads.count, 0)
    }

    func testEntriesAreExact() throws {
        let store = SecretStore(directory: directory)
        try makeDirectory(directory, mode: 0o700)
        let text = #"{"entries":[{"service":"local.nortido.LuminTool.mqtt","account":"a|b","secret":"first"},{"service":"local.nortido.LuminTool.mqtt","account":"a|b","secret":"second"},{"service":"local.nortido.LuminTool.mqtt","account":"a","secret":"short"}]}"#
        try writeFile(text, to: store.file)
        let legacy = FakeLegacy(.absent)
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "a|b", legacy: legacy), "first")
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "a", legacy: legacy), "short")
        try store.save("new", service: Self.mqtt, account: "a|b")
        XCTAssertEqual(try entries(store).filter { $0.account == "a|b" }, [SecretEntry(service: Self.mqtt, account: "a|b", secret: "new")])
        XCTAssertEqual(try store.secret(service: Self.mqtt, account: "a", legacy: legacy), "short")
        XCTAssertEqual(try store.secret(service: Self.esphome, account: "a", legacy: legacy), nil)
        XCTAssertEqual(legacy.reads, [[Self.esphome, "a"]])
    }
}
