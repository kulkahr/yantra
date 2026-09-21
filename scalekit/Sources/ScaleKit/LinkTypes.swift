import Foundation

/// GATT UUIDs of the A6 profile (ports of `IDeviceServiceProfiles`).
public enum GATT {
    public static let a6Service = UUID(uuidString: "0000A602-0000-1000-8000-00805F9B34FB")!
    public static let deviceInfoService = UUID(uuidString: "0000180A-0000-1000-8000-00805F9B34FB")!

    public static let notifyData = UUID(uuidString: "0000A621-0000-1000-8000-00805F9B34FB")!       // device → app
    public static let writeAck = UUID(uuidString: "0000A622-0000-1000-8000-00805F9B34FB")!         // app → device ACK
    public static let writeData = UUID(uuidString: "0000A624-0000-1000-8000-00805F9B34FB")!        // app → device cmd
    public static let notifyAck = UUID(uuidString: "0000A625-0000-1000-8000-00805F9B34FB")!        // device → app ACK
    public static let featureInfo = UUID(uuidString: "0000A641-0000-1000-8000-00805F9B34FB")!      // read
    public static let voltage = UUID(uuidString: "0000A640-0000-1000-8000-00805F9B34FB")!          // read
}

/// An action the state machine asks the host (BLE driver) to perform.
public enum LinkAction: Equatable {
    case connect(macOrIdentifier: String)
    case discoverServices
    case enableNotify(characteristic: UUID)
    case read(characteristic: UUID)
    case write(characteristic: UUID, data: [UInt8])
    case disconnect
}

/// An event the host reports back to the state machine.
public enum LinkEvent: Equatable {
    case connected
    case servicesDiscovered
    case notifyEnabled(characteristic: UUID)
    case readResponse(characteristic: UUID, data: [UInt8])
    case notifyData(characteristic: UUID, data: [UInt8])
    case disconnected
    case commandTimedOut           // host timer: 3 s resend window elapsed
}

/// Firmware-version helpers shared by machines.
public enum FirmwareCompat {
    /// Decompiled: `Security.code.compareTo(fw) <= 0` → XOR obfuscation active.
    public static func usesXor(_ firmwareVersion: String) -> Bool {
        A6Security.isXorVariant(firmwareVersion: firmwareVersion)
    }
}

/// Result-value extraction — literal port of the decompiled pattern
/// `toInt(hexToBytes(formatWithZero(data, 8)))` (pad the payload hex to ≥8 chars
/// with leading zeros, then read the FIRST 4 bytes as a big-endian int).
///
/// KNOWN AMBIGUITY (verify in experiment E1): for result packets shaped
/// `[cmd(2B), result(1B)]` this yields `0x0002XX`-style values that can never
/// equal the success/fail constants 1/2, while ACK packets (payload = status
/// only) parse correctly. The official app is byte-compatible with whatever the
/// scale really sends; the fallback below covers the `[cmd, result(1B)]` shape.
public enum ResultValue {
    public static let success = 1
    public static let failure = 2

    /// Literal decompiled port.
    public static func parseLiteral(_ payload: [UInt8]) -> Int {
        var hex = A6Hex.encode(payload)
        if hex.count < 8 {
            hex = String(repeating: "0", count: 8 - hex.count) + hex
        }
        let bytes = A6Hex.decode(hex)
        guard bytes.count >= 4 else { return -1 }
        return A6Bytes.toInt(bytes, at: 0)
    }

    /// Parse with fallback: if the literal port yields neither 1 nor 2 and the
    /// payload looks like `[cmd(2B), result(1B)]`, read the trailing result byte.
    public static func parse(_ payload: [UInt8]) -> (value: Int, usedFallback: Bool) {
        let literal = parseLiteral(payload)
        if literal == success || literal == failure {
            return (literal, false)
        }
        if payload.count == 3 {
            return (Int(payload[2]) & 0xFF, true)
        }
        return (literal, false)
    }
}

/// ACK frame status inside a decoded count==0 packet (payload = [status]).
public enum AckStatus {
    case ok
    case fail
    case unknown(Int)

    init(_ raw: Int) {
        switch raw {
        case 1: self = .ok
        case 2: self = .fail
        default: self = .unknown(raw)
        }
    }
}
