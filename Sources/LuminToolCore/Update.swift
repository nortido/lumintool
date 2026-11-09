import CryptoKit
import Foundation

public struct AppVersion: Comparable {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard (1...9).contains(piece.utf8.count), piece.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    private static func padded(_ lhs: AppVersion, _ rhs: AppVersion) -> [(Int, Int)] {
        (0..<max(lhs.parts.count, rhs.parts.count)).map { index in
            (index < lhs.parts.count ? lhs.parts[index] : 0, index < rhs.parts.count ? rhs.parts[index] : 0)
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        padded(lhs, rhs).allSatisfy { $0.0 == $0.1 }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        guard let pair = padded(lhs, rhs).first(where: { $0.0 != $0.1 }) else { return false }
        return pair.0 < pair.1
    }
}

public struct UpdateHosts: Equatable {
    public var scheme: String
    public var names: Set<String>
    public var suffixes: [String]
    public var port: Int

    public init(scheme: String, names: Set<String>, suffixes: [String], port: Int) {
        self.scheme = scheme
        self.names = names
        self.suffixes = suffixes
        self.port = port
    }

    public static let github = UpdateHosts(scheme: "https", names: ["api.github.com", "github.com"], suffixes: [".githubusercontent.com"], port: 443)

    public func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == scheme, url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        guard names.contains(host) || suffixes.contains(where: { host.hasSuffix($0) }) else { return false }
        return url.port == nil || url.port == port
    }
}

public struct UpdateSource {
    public var latest: URL
    public var page: URL
    public var hosts: UpdateHosts

    public init(latest: URL, page: URL, hosts: UpdateHosts) {
        self.latest = latest
        self.page = page
        self.hosts = hosts
    }

    public static let github = UpdateSource(
        latest: URL(string: "https://api.github.com/repos/nortido/lumintool/releases/latest")!,
        page: URL(string: "https://github.com/nortido/lumintool/releases/latest")!,
        hosts: .github)
}

public struct UpdateOffer: Equatable {
    public var version: String
    public var url: URL
    public var size: Int
    public var sha256: String

    public init(version: String, url: URL, size: Int, sha256: String) {
        self.version = version
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

public enum UpdateCheck: Equatable {
    case upToDate
    case available(UpdateOffer)
    case notInstallable(String)
}

public enum UpdateProblem: Error, Equatable {
    case unavailable, rateLimited, download, verification, install, blocked

    public var message: String {
        switch self {
        case .unavailable: return L("Could not check for updates.")
        case .rateLimited: return L("Too many requests to GitHub. Try again later.")
        case .download: return L("Could not download the update.")
        case .verification: return L("The update failed verification.")
        case .install: return L("Could not install the update.")
        case .blocked: return L("macOS blocked the update.")
        }
    }

    public static func forRename(errno: Int32) -> UpdateProblem {
        errno == EPERM ? .blocked : .install
    }
}

public enum UpdateRelease {
    public static let maxSize = 50 * 1024 * 1024

    public static func problem(status: Int) -> UpdateProblem? {
        switch status {
        case 200: return nil
        case 403, 429: return .rateLimited
        default: return .unavailable
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int?
        let browserDownloadUrl: String?
        let digest: String?
    }

    public static func evaluate(_ json: Data, current: AppVersion, hosts: UpdateHosts) throws -> UpdateCheck {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard json.count <= 1024 * 1024, let release = try? decoder.decode(Release.self, from: json) else { throw UpdateProblem.unavailable }
        if release.draft || release.prerelease { return .upToDate }
        let version = String(release.tagName.dropFirst())
        guard release.tagName.hasPrefix("v"), let latest = AppVersion(version) else { throw UpdateProblem.unavailable }
        guard latest > current else { return .upToDate }
        guard let asset = release.assets.first(where: { $0.name == "LuminTool-\(version).zip" }),
              let sha256 = UpdateDigest.expected(asset.digest),
              let url = asset.browserDownloadUrl.flatMap(URL.init(string:)), hosts.allows(url),
              let size = asset.size, (1...maxSize).contains(size)
        else { return .notInstallable(version) }
        return .available(UpdateOffer(version: version, url: url, size: size, sha256: sha256))
    }
}

public enum UpdateDigest {
    public static func expected(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return hex.lowercased()
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum UpdateBundle {
    public static let identifier = "local.nortido.LuminTool"
    public static let executable = "LuminTool"

    public static func installable(path: String, identifier: String?, writable: Bool) -> Bool {
        path.hasSuffix(".app") && !path.contains("/AppTranslocation/") && identifier == Self.identifier && writable
    }

    public static func verify(_ info: [String: Any], version: String, current: AppVersion, system: OperatingSystemVersion) throws {
        let running = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        guard info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleExecutable"] as? String == executable,
              info["CFBundleShortVersionString"] as? String == version,
              let offered = AppVersion(version), offered > current,
              let minimum = (info["LSMinimumSystemVersion"] as? String).flatMap(AppVersion.init),
              let running, minimum <= running
        else { throw UpdateProblem.verification }
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 86_400

    public static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= interval || elapsed < 0
    }
}

public enum UpdateLoginItem {
    public static func shouldRegister(flag: Bool, enabledNow: Bool) -> Bool {
        flag && !enabledNow
    }
}
