import CoreGraphics
import ColorSync
import Darwin
import Foundation

public actor SystemBrightness {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let canChange: CanChange?
    private let get: Get?
    private let set: Set?

    public init() {
        // DisplayServices is private and has no SDK headers, so its symbols are loaded at runtime
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        library = handle
        canChange = handle.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
            .map { unsafeBitCast($0, to: CanChange.self) }
        get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: Get.self) }
        set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: Set.self) }
    }

    deinit { if let library { dlclose(library) } }

    private func resolve(_ uuid: String) throws -> CGDirectDisplayID {
        try Task.checkCancellation()
        guard !uuid.isEmpty else { throw LuminToolError.message(L("Choose an external monitor.")) }
        guard canChange != nil, get != nil, set != nil else {
            throw LuminToolError.message(L("The brightness service is not available in this macOS version."))
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            throw LuminToolError.message(L("Could not get the list of monitors from macOS."))
        }
        for display in displays.prefix(Int(count)) where CGDisplayIsBuiltin(display) == 0 {
            guard let id = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { continue }
            let identifier = CFUUIDCreateString(nil, id) as String
            if identifier.caseInsensitiveCompare(uuid) == .orderedSame {
                guard canChange?(display) == true else {
                    throw LuminToolError.message(L("macOS does not support system brightness for this monitor on the current connection."))
                }
                return display
            }
        }
        throw LuminToolError.message(L("The external monitor is disconnected."))
    }

    private func read(_ display: CGDirectDisplayID) throws -> Double {
        var value: Float = 0
        let status = get!(display, &value)
        guard status == 0, value.isFinite, (0...1).contains(value) else {
            throw LuminToolError.message(String(format: L("macOS returned invalid brightness (%d)."), status))
        }
        return Double(value)
    }

    public func brightness(display: String) throws -> Double {
        try read(resolve(display))
    }

    public func setBrightness(_ value: Double, display: String) throws -> Double {
        guard value.isFinite, (0...1).contains(value) else { throw LuminToolError.message(L("Brightness must be from 0 to 100%.")) }
        let id = try resolve(display)
        try Task.checkCancellation()
        let status = set!(id, Float(value))
        guard status == 0 else { throw LuminToolError.message(String(format: L("macOS did not change the brightness (%d)."), status)) }
        return Double(Float(value))
    }
}
