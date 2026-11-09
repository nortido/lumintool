import AppKit
import Foundation
import LuminToolCore
import Security
import ServiceManagement

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateOffer)
    case notInstallable(String)
    case downloading(String)
    case installing(String)
    case failed(UpdateProblem)
    case installed(String)
}

enum UpdatePin {
    case none
    case requirement(SecRequirement)
    case unknown
}

private final class AllowedRedirects: NSObject, URLSessionTaskDelegate {
    let hosts: UpdateHosts

    init(hosts: UpdateHosts) { self.hosts = hosts }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(hosts.allows(request.url) ? request : nil)
    }
}

@MainActor
final class Updater {
    private(set) var phase = UpdatePhase.idle {
        didSet { onChange?(phase) }
    }
    var onChange: ((UpdatePhase) -> Void)?
    let source: UpdateSource
    private let bundleURL: URL
    private let currentVersion: String?
    private let system: OperatingSystemVersion
    private let defaults: UserDefaults
    private let relaunch: @MainActor (URL, () -> Void) throws -> Void
    private let toolTimeout: TimeInterval
    private let pin: UpdatePin
    private var enabled: () -> Bool = { false }
    private var checkTask: Task<Void, Never>?
    private var manualCheck = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static let lastCheckKey = "lastUpdateCheck"

    init(source: UpdateSource = .github, bundleURL: URL = Bundle.main.bundleURL,
         currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
         system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         defaults: UserDefaults = .standard,
         relaunch: @escaping @MainActor (URL, () -> Void) throws -> Void = Updater.relaunch,
         toolTimeout: TimeInterval = 120, pin: UpdatePin = Updater.runningPin()) {
        self.source = source
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.system = system
        self.defaults = defaults
        self.relaunch = relaunch
        self.toolTimeout = toolTimeout
        self.pin = pin
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        checkTask?.cancel()
    }

    func startAutomaticChecks(enabled: @escaping () -> Bool) {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        self.enabled = enabled
        checkIfDue()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfDue() {
        guard enabled(), UpdateSchedule.isDue(last: defaults.object(forKey: Self.lastCheckKey) as? Date, now: Date()) else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        switch phase {
        case .downloading, .installing, .installed: return
        default: break
        }
        if checkTask != nil {
            if manual && !manualCheck {
                manualCheck = true
                phase = .checking
            }
            return
        }
        manualCheck = manual
        if manual { phase = .checking }
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<UpdatePhase, UpdateProblem>
            do { result = .success(try await self.fetchLatest()) } catch { result = .failure(error as? UpdateProblem ?? .unavailable) }
            guard !Task.isCancelled else { return }
            let manual = self.manualCheck
            self.checkTask = nil
            self.manualCheck = false
            switch result {
            case .success(let found):
                self.defaults.set(Date(), forKey: Self.lastCheckKey)
                self.phase = found
            case .failure(let problem):
                if manual { self.phase = .failed(problem) }
            }
        }
    }

    private var userAgent: String { "LuminTool/\(currentVersion ?? "")" }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: AllowedRedirects(hosts: source.hosts), delegateQueue: nil)
    }

    private func fetchLatest() async throws -> UpdatePhase {
        guard let current = currentVersion.flatMap(AppVersion.init), source.hosts.allows(source.latest) else { throw UpdateProblem.unavailable }
        var request = URLRequest(url: source.latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, source.hosts.allows(http.url)
        else { throw UpdateProblem.unavailable }
        if let problem = UpdateRelease.problem(status: http.statusCode) { throw problem }
        switch try UpdateRelease.evaluate(data, current: current, hosts: source.hosts) {
        case .upToDate: return .upToDate
        case .notInstallable(let version): return .notInstallable(version)
        case .available(let offer): return installable() ? .available(offer) : .notInstallable(offer.version)
        }
    }

    private func installable() -> Bool {
        let bundle = bundleURL.resolvingSymlinksInPath()
        let identifier = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
        let files = FileManager.default
        let writable = files.isWritableFile(atPath: bundle.path) && files.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        return UpdateBundle.installable(path: bundle.path, identifier: identifier, writable: writable)
    }

    nonisolated static func runningPin() -> UpdatePin {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return .unknown }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let certificates = (info[kSecCodeInfoCertificates as String] as? [Any])?.count ?? 0
        switch UpdateSignature.classify(flags: flags, certificates: certificates) {
        // An ad-hoc requirement is this build's cdhash, so pinning it would reject every update.
        case .adhoc: return .none
        case .unknown: return .unknown
        case .certificate:
            var requirement: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return .unknown }
            return .requirement(requirement)
        }
    }

    static func satisfies(_ app: URL, _ requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    func prepare(_ offer: UpdateOffer) async throws -> (staging: URL, app: URL) {
        let files = FileManager.default
        guard let staging = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true) else {
            throw UpdateProblem.install
        }
        do {
            guard let current = currentVersion.flatMap(AppVersion.init) else { throw UpdateProblem.verification }
            let zip = staging.appendingPathComponent("LuminTool-\(offer.version).zip")
            try await download(offer, to: zip)
            let digest = try? await Task.detached { try UpdateDigest.sha256Hex(of: zip) }.value
            guard digest == offer.sha256 else { throw UpdateProblem.verification }
            let unpacked = staging.appendingPathComponent("x")
            guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: toolTimeout) == 0 else { throw UpdateProblem.install }
            let app = unpacked.appendingPathComponent("LuminTool.app")
            let kind = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind?.isDirectory == true, kind?.isSymbolicLink == false,
                  let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            else { throw UpdateProblem.verification }
            try UpdateBundle.verify(info, version: offer.version, current: current, system: system)
            guard await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: toolTimeout) == 0 else { throw UpdateProblem.verification }
            switch pin {
            case .none: break
            case .requirement(let requirement):
                guard Self.satisfies(app, requirement) else { throw UpdateProblem.verification }
            case .unknown: throw UpdateProblem.verification
            }
            return (staging, app)
        } catch {
            try? files.removeItem(at: staging)
            throw error as? UpdateProblem ?? .install
        }
    }

    private func download(_ offer: UpdateOffer, to file: URL) async throws {
        guard source.hosts.allows(offer.url) else { throw UpdateProblem.download }
        var request = URLRequest(url: offer.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        guard let (temporary, response) = try? await session.download(for: request) else { throw UpdateProblem.download }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, source.hosts.allows(http.url) else { throw UpdateProblem.download }
        do { try FileManager.default.moveItem(at: temporary, to: file) } catch { throw UpdateProblem.install }
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size == offer.size, (1...UpdateRelease.maxSize).contains(size) else { throw UpdateProblem.download }
    }

    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }

    func install(beforeQuit: @escaping () -> Void) {
        guard case .available(let offer) = phase else { return }
        checkTask?.cancel()
        checkTask = nil
        manualCheck = false
        phase = .downloading(offer.version)
        Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await self.prepare(offer)
                self.phase = .installing(offer.version)
                do {
                    try Self.replace(target: self.bundleURL, with: staged.app, version: offer.version)
                } catch {
                    // A failed swap-back leaves the old bundle in staging: keep it then.
                    let info = NSDictionary(contentsOf: staged.app.appendingPathComponent("Contents/Info.plist"))
                    if info?["CFBundleShortVersionString"] as? String == offer.version { try? FileManager.default.removeItem(at: staged.staging) }
                    throw error
                }
                try? FileManager.default.removeItem(at: staged.staging)
            } catch {
                self.phase = .failed(error as? UpdateProblem ?? .install)
                return
            }
            do { try self.relaunch(self.bundleURL, beforeQuit) } catch { self.phase = .installed(offer.version) }
        }
    }

    static func replace(target: URL, with staged: URL, version: String) throws {
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateProblem.forRename(errno: errno) }
        let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == version else {
            _ = renamex_np(staged.path, target.path, UInt32(RENAME_SWAP))
            throw UpdateProblem.install
        }
    }

    // open runs only after this PID is gone, so two instances never run; after 30 s it gives up without opening.
    private static let waiterScript = #"n=0; while kill -0 "$1" 2>/dev/null; do n=$((n+1)); [ "$n" -ge 150 ] && exit 1; sleep 0.2; done; shift; exec "$@""#
    private static let loginItemKey = "updateLoginItem"

    static func spawnWaiter(pid: Int32, command: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", waiterScript, "sh", String(pid)] + command
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateProblem.install }
    }

    static func relaunch(_ app: URL, beforeQuit: () -> Void) throws {
        try spawnWaiter(pid: getpid(), command: ["/usr/bin/open", app.path])
        if SMAppService.mainApp.status == .enabled { UserDefaults.standard.set(true, forKey: loginItemKey) }
        beforeQuit()
        // terminate can stall when called from inside a Task; exit(0) is the fallback (settings are saved on every change).
        DispatchQueue.main.async { NSApp.terminate(nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    static func repairLoginItemAfterUpdate() {
        let defaults = UserDefaults.standard
        let flag = defaults.bool(forKey: loginItemKey)
        defaults.removeObject(forKey: loginItemKey)
        if UpdateLoginItem.shouldRegister(flag: flag, enabledNow: SMAppService.mainApp.status == .enabled) {
            try? SMAppService.mainApp.register()
        }
    }
}
