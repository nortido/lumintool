import Foundation

public struct LineBuffer {
    private let maxLength: Int
    private var pending: [UInt8] = []
    private var discarding = false

    public init(maxLength: Int) { self.maxLength = maxLength }

    public mutating func append(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            switch byte {
            case 0x0A:
                if !discarding { lines.append(String(decoding: pending, as: UTF8.self)) }
                discarding = false
                pending.removeAll(keepingCapacity: true)
            case 0x0D:
                break
            default:
                guard !discarding else { continue }
                pending.append(byte)
                // The rest of an oversize line (wrong baud rate) must not parse as a short line
                if pending.count > maxLength {
                    discarding = true
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        return lines
    }
}

public enum SerialReading: Equatable {
    case lux(Double), unavailable, ignored
}

public enum SerialLine {
    public static func parse(_ line: String) -> SerialReading {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        var luxLabel = true
        if let separator = rest.firstIndex(where: { $0 == ":" || $0 == "=" }) {
            let label = rest[..<separator].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" }) else { return .ignored }
            // Boards print other readings too (temperature, humidity); only a lux-like label or unit counts
            luxLabel = ["lux", "illuminance", "light", "ambient light", "als"].contains(label.lowercased())
            rest = rest[rest.index(after: separator)...]
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        let negative = rest.hasPrefix("-")
        if negative { rest = rest.dropFirst() }
        let special = ["nan", "inf"].first { rest.lowercased().hasPrefix($0) }
        var value = 0.0
        if let special {
            rest = rest.dropFirst(special.count)
        } else {
            let whole = rest.prefix { $0.isASCII && $0.isNumber }
            guard !whole.isEmpty else { return .ignored }
            var number = whole
            var tail = rest.dropFirst(whole.count)
            if tail.hasPrefix(".") {
                let fraction = tail.dropFirst().prefix { $0.isASCII && $0.isNumber }
                guard !fraction.isEmpty else { return .ignored }
                number = rest.prefix(whole.count + 1 + fraction.count)
                tail = rest.dropFirst(number.count)
            }
            guard let parsed = Double(number) else { return .ignored }
            value = parsed
            rest = tail
        }
        let unit = rest.trimmingCharacters(in: .whitespaces).lowercased()
        guard ["", "lx", "lux"].contains(unit), luxLabel || !unit.isEmpty else { return .ignored }
        return special != nil || negative || !value.isFinite ? .unavailable : .lux(value)
    }
}

public enum SerialPorts {
    public static func candidates(_ names: [String]) -> [String] {
        names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && $0 != "cu.debug-console" }
            .sorted()
            .map { "/dev/" + $0 }
    }
}
