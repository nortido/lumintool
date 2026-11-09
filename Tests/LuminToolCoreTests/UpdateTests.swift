import CryptoKit
import XCTest
@testable import LuminToolCore

final class UpdateTests: XCTestCase {
    private static let digest = "74a1d648f2376dbdb1671d02e1fa79c21a9c73e8faa42fe2dc14b87e81a050a0"
    private static let downloadURL = "https://github.com/nortido/lumintool/releases/download/v1.3.1/LuminTool-1.3.1.zip"
    private var tempFiles: [URL] = []

    override func tearDown() {
        for file in tempFiles { try? FileManager.default.removeItem(at: file) }
        tempFiles = []
        super.tearDown()
    }

    private func version(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> AppVersion {
        try XCTUnwrap(AppVersion(text), file: file, line: line)
    }

    private func asset(name: String = "LuminTool-1.3.1.zip", size: Int = 407818, url: String = UpdateTests.downloadURL, digest: String? = "\"sha256:\(UpdateTests.digest)\"") -> String {
        let digestField = digest.map { #","digest":\#($0)"# } ?? ""
        return #"{"id":1,"name":"\#(name)","size":\#(size),"content_type":"application/zip","browser_download_url":"\#(url)"\#(digestField)}"#
    }

    private func release(tag: String = "v1.3.1", draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil) -> Data {
        let list = (assets ?? [asset()]).joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/nortido/lumintool/releases/tag/\#(tag)","assets":[\#(list)]}"#.utf8)
    }

    private func evaluate(_ json: Data, current: String = "1.3.0") throws -> UpdateCheck {
        try UpdateRelease.evaluate(json, current: try version(current), hosts: .github)
    }

    private func assertProblem(_ expected: UpdateProblem, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? UpdateProblem, expected, file: file, line: line)
        }
    }

    func testVersionParsing() {
        XCTAssertEqual(AppVersion("1.3.1")?.parts, [1, 3, 1])
        XCTAssertEqual(AppVersion("2")?.parts, [2])
        for text in ["", "v1.3.1", "1..3", "1.3.", ".1", "1.3.1-beta", " 1.3", "1.3 ", "1.2.3.4.5", "1234567890", "١.٢", "１.２"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testVersionOrder() throws {
        XCTAssertGreaterThan(try version("1.10.0"), try version("1.9.0"))
        XCTAssertEqual(try version("1.3"), try version("1.3.0"))
        XCTAssertGreaterThan(try version("1.3.1"), try version("1.3"))
        XCTAssertGreaterThan(try version("2"), try version("1.99.99"))
        XCTAssertFalse(try version("1.3.1") > version("1.3.1"))
    }

    func testHosts() {
        let hosts = UpdateHosts.github
        for text in ["https://api.github.com/repos/x", "https://github.com/nortido/lumintool/releases/download/v1/a.zip", "https://release-assets.githubusercontent.com/a", "https://GITHUB.COM/a", "https://github.com:443/a"] {
            XCTAssertTrue(hosts.allows(URL(string: text)), text)
        }
        XCTAssertFalse(hosts.allows(nil))
        for text in ["http://github.com/a", "https://evilgithubusercontent.com/a", "https://githubusercontent.com.evil.com/a", "https://github.com.evil.com/a", "https://u:p@github.com/a", "https://github.com:8443/a", "https://githubusercontent.com/a"] {
            XCTAssertFalse(hosts.allows(URL(string: text)), text)
        }
    }

    func testLatestReleaseOffer() throws {
        let offer = UpdateOffer(version: "1.3.1", url: try XCTUnwrap(URL(string: Self.downloadURL)), size: 407818, sha256: Self.digest)
        XCTAssertEqual(try evaluate(release()), .available(offer))
        XCTAssertEqual(try evaluate(release(), current: "1.3.1"), .upToDate)
        XCTAssertEqual(try evaluate(release(), current: "1.4.0"), .upToDate)
        let signature = asset(name: "LuminTool-1.3.1.zip.sig", size: 64, digest: #""sha256:\#(String(repeating: "0", count: 64))""#)
        XCTAssertEqual(try evaluate(release(assets: [signature, asset()])), .available(offer))
        XCTAssertEqual(try evaluate(release(assets: [asset(digest: #""sha256:\#(Self.digest.uppercased())""#)])), .available(offer))
    }

    func testReleaseNotInstallable() throws {
        let cases = [
            asset(digest: "null"),
            asset(digest: nil),
            asset(digest: #""md5:\#(String(repeating: "a", count: 32))""#),
            asset(digest: #""sha256:\#(Self.digest.dropLast())""#),
            asset(digest: #""sha256:\#(Self.digest.dropLast())g""#),
            asset(name: "LuminTool-1.3.1-arm64.zip"),
            asset(name: "LuminTool-v1.3.1.zip"),
            asset(url: "http://github.com/nortido/lumintool/releases/download/v1.3.1/LuminTool-1.3.1.zip"),
            asset(url: "https://example.com/nortido/lumintool/releases/download/v1.3.1/LuminTool-1.3.1.zip"),
            asset(size: 0),
            asset(size: UpdateRelease.maxSize + 1)
        ]
        for item in cases {
            XCTAssertEqual(try evaluate(release(assets: [item])), .notInstallable("1.3.1"), item)
        }
    }

    func testReleaseRejected() throws {
        for tag in ["1.3.1", "x1.3.1", "V1.3.1", "v1.3.1-beta", "v", "release-1.3.1"] {
            assertProblem(.unavailable) { _ = try self.evaluate(self.release(tag: tag)) }
        }
        assertProblem(.unavailable) { _ = try self.evaluate(Data("{\"tag_name\":".utf8)) }
        assertProblem(.unavailable) { _ = try self.evaluate(Data("[]".utf8)) }
        let padded = release() + Data(String(repeating: " ", count: 1024 * 1024).utf8)
        assertProblem(.unavailable) { _ = try self.evaluate(padded) }
        XCTAssertEqual(try evaluate(release(draft: true)), .upToDate)
        XCTAssertEqual(try evaluate(release(prerelease: true)), .upToDate)
    }

    func testStatusProblem() {
        XCTAssertNil(UpdateRelease.problem(status: 200))
        for status in [403, 429] { XCTAssertEqual(UpdateRelease.problem(status: status), .rateLimited, "\(status)") }
        for status in [302, 404, 500] { XCTAssertEqual(UpdateRelease.problem(status: status), .unavailable, "\(status)") }
    }

    func testRenameErrno() {
        XCTAssertEqual(UpdateProblem.forRename(errno: EPERM), .blocked)
        for code in [EACCES, EXDEV, ENOTSUP, ENOENT] {
            XCTAssertEqual(UpdateProblem.forRename(errno: code), .install, "\(code)")
        }
    }

    func testExpectedDigest() {
        XCTAssertEqual(UpdateDigest.expected("sha256:" + Self.digest.uppercased()), Self.digest)
        XCTAssertNil(UpdateDigest.expected(nil))
        XCTAssertNil(UpdateDigest.expected("sha512:" + Self.digest + Self.digest))
        XCTAssertNil(UpdateDigest.expected("sha256:" + Self.digest.dropLast()))
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-\(UUID().uuidString)")
        tempFiles.append(url)
        try data.write(to: url)
        return url
    }

    func testDigestOfFile() throws {
        XCTAssertEqual(try UpdateDigest.sha256Hex(of: tempFile(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try UpdateDigest.sha256Hex(of: tempFile(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let large = Data((0..<(3 * 1024 * 1024 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let oneShot = SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try UpdateDigest.sha256Hex(of: tempFile(large)), oneShot)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try UpdateDigest.sha256Hex(of: missing))
    }

    func testBundleVerification() throws {
        let good: [String: Any] = [
            "CFBundleIdentifier": "local.nortido.LuminTool",
            "CFBundleExecutable": "LuminTool",
            "CFBundleShortVersionString": "1.4.0",
            "LSMinimumSystemVersion": "14.0"
        ]
        let current = try version("1.3.1")
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertNoThrow(try UpdateBundle.verify(good, version: "1.4.0", current: current, system: sonoma))
        XCTAssertNoThrow(try UpdateBundle.verify(good, version: "1.4.0", current: current, system: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)))

        func changed(_ key: String, _ value: String?) -> [String: Any] {
            var info = good
            info[key] = value
            return info
        }
        let cases: [(String, [String: Any], String, AppVersion)] = [
            ("wrong id", changed("CFBundleIdentifier", "local.nortido.Other"), "1.4.0", current),
            ("missing id", changed("CFBundleIdentifier", nil), "1.4.0", current),
            ("Info 1.3.9", changed("CFBundleShortVersionString", "1.3.9"), "1.4.0", current),
            ("not newer", good, "1.4.0", try version("1.4.0")),
            ("Info 1.4", changed("CFBundleShortVersionString", "1.4"), "1.4.0", current),
            ("executable", changed("CFBundleExecutable", "Other"), "1.4.0", current),
            ("min 99.0", changed("LSMinimumSystemVersion", "99.0"), "1.4.0", current),
            ("min missing", changed("LSMinimumSystemVersion", nil), "1.4.0", current),
            ("min abc", changed("LSMinimumSystemVersion", "abc"), "1.4.0", current)
        ]
        for (label, info, offered, running) in cases {
            XCTAssertThrowsError(try UpdateBundle.verify(info, version: offered, current: running, system: sonoma), label) { error in
                XCTAssertEqual(error as? UpdateProblem, .verification, label)
            }
        }
    }

    func testScheduleIsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateSchedule.isDue(last: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(last: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(60), now: now))
    }

    func testInstallableLocation() {
        let id = "local.nortido.LuminTool"
        XCTAssertTrue(UpdateBundle.installable(path: "/Applications/LuminTool.app", identifier: id, writable: true))
        XCTAssertFalse(UpdateBundle.installable(path: "/Applications/LuminTool.app", identifier: id, writable: false))
        XCTAssertFalse(UpdateBundle.installable(path: "/Applications/LuminTool.app", identifier: nil, writable: true))
        XCTAssertFalse(UpdateBundle.installable(path: "/Applications/LuminTool.app", identifier: "local.nortido.Other", writable: true))
        XCTAssertFalse(UpdateBundle.installable(path: "/private/var/folders/ab/T/AppTranslocation/1F2E/d/LuminTool.app", identifier: id, writable: true))
        XCTAssertFalse(UpdateBundle.installable(path: "/Applications/LuminTool", identifier: id, writable: true))
    }

    func testLoginItemRepair() {
        XCTAssertTrue(UpdateLoginItem.shouldRegister(flag: true, enabledNow: false))
        XCTAssertFalse(UpdateLoginItem.shouldRegister(flag: true, enabledNow: true))
        XCTAssertFalse(UpdateLoginItem.shouldRegister(flag: false, enabledNow: false))
        XCTAssertFalse(UpdateLoginItem.shouldRegister(flag: false, enabledNow: true))
    }

    func testSignatureClassification() {
        XCTAssertEqual(UpdateSignature.classify(flags: 0x2, certificates: 0), .adhoc)
        XCTAssertEqual(UpdateSignature.classify(flags: 0x20002, certificates: 0), .adhoc)
        XCTAssertEqual(UpdateSignature.classify(flags: 0x2, certificates: 1), .adhoc)
        XCTAssertEqual(UpdateSignature.classify(flags: 0, certificates: 1), .certificate)
        XCTAssertEqual(UpdateSignature.classify(flags: 0x10000, certificates: 2), .certificate)
        XCTAssertEqual(UpdateSignature.classify(flags: nil, certificates: 1), .unknown)
        XCTAssertEqual(UpdateSignature.classify(flags: 0, certificates: 0), .unknown)
    }
}
