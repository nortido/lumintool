import Foundation
import LuminToolCore

private final class Port: @unchecked Sendable {
    let chunks: AsyncStream<Data>
    private let source: DispatchSourceRead
    private let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closing = false

    init(path: String, baud: Int) throws {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw Self.failure(errno) }
        var options = termios()
        var code: Int32 = 0
        if ioctl(fd, TIOCEXCL) != 0 || tcgetattr(fd, &options) != 0 {
            code = errno
        } else {
            cfmakeraw(&options)
            cfsetspeed(&options, speed_t(baud))
            options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
            if tcsetattr(fd, TCSANOW, &options) != 0 { code = errno }
        }
        if code != 0 {
            Darwin.close(fd)
            throw Self.failure(code)
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let closed = closed
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "local.nortido.LuminTool.serial"))
        var buffer = [UInt8](repeating: 0, count: 1024)
        source.setEventHandler {
            let count = read(fd, &buffer, buffer.count)
            let code = errno
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count == 0 || (code != EAGAIN && code != EINTR) {
                continuation.finish()
                source.cancel()
            }
        }
        // The only place the descriptor is closed, so it is closed exactly once
        source.setCancelHandler {
            Darwin.close(fd)
            continuation.finish()
            closed.signal()
        }
        continuation.onTermination = { _ in source.cancel() }
        source.resume()
        chunks = stream
        self.source = source
    }

    // Waits for the cancel handler so the next session can reopen the exclusive port; never call from the serial queue
    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closing = true }
            return !closing
        }
        guard first else { return }
        source.cancel()
        _ = closed.wait(timeout: .now() + 0.5)
    }

    private static func failure(_ code: Int32) -> LuminToolError {
        switch code {
        case EBUSY: return .message(L("The USB port is in use by another app."))
        case ENOENT, ENXIO, ENODEV: return .message(L("USB device disconnected"))
        default: return .message(String(format: L("Could not open the USB port (%d)."), Int(code)))
        }
    }
}

@MainActor
final class SerialConnection {
    private enum State { case waiting, reading, invalid, silent }
    @MainActor private final class Health {
        var lastReading = ProcessInfo.processInfo.systemUptime
        var state = State.waiting
    }
    var onLux: ((Double?) -> Void)?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var port: Port?

    deinit {
        task?.cancel()
        port?.close()
    }

    func stop() {
        task?.cancel()
        task = nil
        port?.close()
        port = nil
        onLux?(nil)
    }

    func start(path: String, baud: Int) {
        stop()
        let onLux = onLux
        let onStatus = onStatus
        task = Task { @MainActor [weak self] in
            var first = true
            while !Task.isCancelled {
                if first { onStatus?(L("Connecting to USB…")) }
                first = false
                do {
                    try await Self.session(path: path, baud: baud, onPort: { [weak self] in self?.port = $0 },
                                           onLux: onLux, onStatus: onStatus)
                } catch {
                    guard !Task.isCancelled else { return }
                    onLux?(nil)
                    onStatus?(error.localizedDescription)
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }

    private static func session(path: String, baud: Int, onPort: (Port) -> Void, onLux: ((Double?) -> Void)?,
                                onStatus: ((String) -> Void)?) async throws {
        let port = try Port(path: path, baud: baud)
        onPort(port)
        let health = Health()
        onStatus?(L("Waiting for data from USB…"))
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled, health.state != .silent,
                      ProcessInfo.processInfo.systemUptime - health.lastReading > 30 else { continue }
                health.state = .silent
                onLux?(nil)
                onStatus?(L("The USB device sends no data."))
            }
        }
        defer {
            watchdog.cancel()
            port.close()
        }
        var lines = LineBuffer(maxLength: 256)
        // The watchdog is a separate task, so cancelling the session must cancel it at once, before a queued tick runs
        await withTaskCancellationHandler {
            for await chunk in port.chunks {
                guard !Task.isCancelled else { return }
                for line in lines.append(chunk) {
                    switch SerialLine.parse(line) {
                    case .lux(let value):
                        health.lastReading = ProcessInfo.processInfo.systemUptime
                        onLux?(value)
                        if health.state != .reading {
                            health.state = .reading
                            onStatus?(L("USB connected"))
                        }
                    case .unavailable:
                        health.lastReading = ProcessInfo.processInfo.systemUptime
                        onLux?(nil)
                        if health.state != .invalid {
                            health.state = .invalid
                            onStatus?(L("The USB device reports no valid illuminance."))
                        }
                    case .ignored:
                        break
                    }
                }
            }
        } onCancel: { watchdog.cancel() }
        guard !Task.isCancelled else { return }
        throw LuminToolError.message(L("USB device disconnected"))
    }
}
