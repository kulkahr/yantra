import Foundation

/// A6 command codes (port of `PacketProfile` command values).
public enum A6Command: UInt16 {
    case deviceRegisterDeviceID = 0x0001
    case deviceRegisterResult   = 0x0002
    case bindNotice             = 0x0003
    case bindResult             = 0x0004
    case unbindNotice           = 0x0005
    case unbindResult           = 0x0006
    case receiverAuth           = 0x0007
    case auth                   = 0x0008
    case receiverInit           = 0x0009
    case responseInit           = 0x000A
    case settingCallback        = 0x1000
    case measureSetting         = 0x4801
    case weightData             = 0x4802
    case pushUserInfo           = 0x1001
    case pushTime               = 0x1002
    case pushTarget             = 0x1003
    case pushUnit               = 0x1004
    case pushClearData          = 0x1005
    case pushFormula            = 0x1006
    case pushHeartRateSwitch    = 0x1007
    case receiveUserInfo        = 0x2001
    case receiveTarget          = 0x2003
    case receiveUnit            = 0x2004
    case newMeasureData         = 0x00E9
    case exception              = 0x00FF
    case unknown                = 0x0000
}

/// Firmware gate for payload obfuscation (`Security.code = "1.4.0.25"`):
/// XOR-with-MAC applies when `firmware >= 1.4.0.25` (string compare, same as decompiled
/// `Security.code.compareTo(firmwareVersion) <= 0`).
public enum A6Security {
    public static let gate = "1.4.0.25"

    public static func isXorVariant(firmwareVersion: String) -> Bool {
        // Java's String.compareTo: lexicographic, shorter-prefix < longer.
        let a = Array(gate.unicodeScalars), b = Array(firmwareVersion.unicodeScalars)
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] <= b[i] }   // gate <= fw → true
        }
        return a.count <= b.count                      // "1.4.0.25" <= "1.4.0.251" → true
    }
}

/// Big-endian integer helpers (port of `DataUtils.to4Bytes(short|int)`, `toShort`, `toInt`).
/// Note: the decompiled `to4Bytes(short)` emits 2 bytes — the name is misleading.
public enum A6Bytes {
    public static func from(short v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    public static func from(int v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    public static func toShort(_ b: [UInt8], at i: Int) -> Int {
        Int(b[i]) << 8 | Int(b[i + 1])
    }
    public static func toInt(_ b: [UInt8], at i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}

/// Hex helpers mirroring the decompiled string-based pipeline.
public enum A6Hex {
    public static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
    public static func decode(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var chars = Array(hex.uppercased())
        if chars.count % 2 == 1 { chars.removeLast() }
        var i = 0
        while i < chars.count {
            if let hi = chars[i].hexValue16, let lo = chars[i + 1].hexValue16 {
                bytes.append(hi << 4 | lo)
            }
            i += 2
        }
        return bytes
    }
}

private extension Character {
    var hexValue16: UInt8? {
        guard let v = hexDigitValue else { return nil }
        return UInt8(v)
    }
}
