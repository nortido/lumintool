import Foundation
import Security

public enum LegacySecret: Equatable {
    case found(String), absent, declined, failed(Int32)

    public init(status: OSStatus, data: Data?) {
        switch status {
        case errSecSuccess:
            if let data, let text = String(data: data, encoding: .utf8) {
                self = .found(text)
            } else {
                self = .failed(errSecSuccess)
            }
        case errSecItemNotFound:
            self = .absent
        case errSecUserCanceled, errSecAuthFailed:
            self = .declined
        default:
            self = .failed(status)
        }
    }
}

public protocol LegacySecrets {
    func read(service: String, account: String) -> LegacySecret
    func delete(service: String, account: String)
}

struct SecretEntry: Codable, Equatable {
    var service: String
    var account: String
    var secret: String?
}

struct SecretFile: Codable {
    var entries: [SecretEntry]
}

public struct SecretStore {
    public static let fileName = "secrets.json"
    public let directory: URL
    public var file: URL { directory.appendingPathComponent(SecretStore.fileName) }
    var beforeVerify: (() -> Void)? = nil

    public init(directory: URL) {
        self.directory = directory
    }

    public func secret(service: String, account: String, legacy: LegacySecrets) throws -> String? {
        var stored = try load()
        if let entry = stored.entry(service: service, account: account) { return entry.secret }
        switch legacy.read(service: service, account: account) {
        case .found(let value):
            stored.entries.append(SecretEntry(service: service, account: account, secret: value))
            try write(stored)
            beforeVerify?()
            // Delete only after the secret reads back from disk, so a lost write never loses the Keychain copy.
            if let reloaded = try? load(), reloaded.entry(service: service, account: account)?.secret == value {
                legacy.delete(service: service, account: account)
            }
            return value
        case .absent, .declined:
            stored.entries.append(SecretEntry(service: service, account: account, secret: nil))
            // Best effort: if this marker is lost, the next launch only asks the Keychain again.
            try? write(stored)
            return nil
        case .failed(let status):
            throw LuminToolError.message(String(format: L("Could not read the token from Keychain (%d)."), status))
        }
    }

    public func save(_ secret: String, service: String, account: String) throws {
        var stored = try load()
        stored.entries.removeAll { $0.service == service && $0.account == account }
        stored.entries.append(SecretEntry(service: service, account: account, secret: secret))
        try write(stored)
    }

    private func load() throws -> SecretFile {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return SecretFile(entries: []) }
            throw Self.readFailure
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { throw Self.readFailure }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.readFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if info.st_mode & 0o077 != 0, fchmod(fd, 0o600) != 0 { throw Self.readFailure }
        guard let data = try? handle.readToEnd() ?? Data(),
              let decoded = try? JSONDecoder().decode(SecretFile.self, from: data) else { throw Self.readFailure }
        return decoded
    }

    private func write(_ stored: SecretFile) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil
            throw Self.writeFailure(Int32(code ?? Int(EIO)))
        }
        var info = stat()
        guard stat(directory.path, &info) == 0 else { throw Self.writeFailure(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Self.writeFailure(EACCES) }
        if info.st_mode & 0o077 != 0, chmod(directory.path, 0o700) != 0 { throw Self.writeFailure(errno) }

        let data: Data
        do { data = try JSONEncoder().encode(stored) } catch { throw Self.writeFailure(EINVAL) }
        let temp = directory.appendingPathComponent(".\(SecretStore.fileName).\(UUID().uuidString)").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.writeFailure(errno) }
        var failure: Int32 = 0
        if fchmod(fd, 0o600) != 0 { failure = errno }
        if failure == 0 {
            failure = data.withUnsafeBytes { buffer -> Int32 in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += count
                }
                return 0
            }
        }
        // fsync alone leaves data in the drive cache; some filesystems lack F_FULLFSYNC.
        if failure == 0, fcntl(fd, F_FULLFSYNC) == -1, fsync(fd) != 0 { failure = errno }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temp, file.path) != 0 { failure = errno }
        guard failure == 0 else {
            unlink(temp)
            throw Self.writeFailure(failure)
        }
        let dirFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        if dirFD >= 0 {
            fsync(dirFD)
            close(dirFD)
        }
    }

    private static var readFailure: LuminToolError {
        .message(L("Could not read the file with saved passwords."))
    }

    private static func writeFailure(_ code: Int32) -> LuminToolError {
        .message(String(format: L("Could not save the token (%d)."), code))
    }
}

private extension SecretFile {
    func entry(service: String, account: String) -> SecretEntry? {
        entries.first { $0.service == service && $0.account == account }
    }
}
