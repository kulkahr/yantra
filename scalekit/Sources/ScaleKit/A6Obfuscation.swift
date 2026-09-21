import Foundation

/// MAC-address helpers + payload obfuscation
/// (ports of `DataUtils.getMacWithoutColon`, `DataUtils.getBytesXorResult`).
public enum A6Obfuscation {

    /// "31:06:1B:CB:0B:D8" → [0x31,0x06,0x1B,0xCB,0x0B,0xD8]
    public static func macBytes(_ mac: String) -> [UInt8] {
        let clean = mac.replacingOccurrences(of: ":", with: "").uppercased()
        guard clean.count == 12, clean.allSatisfy({ $0.isHexDigit }) else { return [] }
        return (0..<6).map { UInt8(clean.subclean(at: $0 * 2), radix: 16)! }
    }

    /// MAC as 12 uppercase hex chars (the "broadcastId" form).
    public static func macHex(_ mac: String) -> String {
        mac.replacingOccurrences(of: ":", with: "").uppercased()
    }

    /// XOR with repeating key; key index cycles over key length
    /// (`getBytesXorResult`: `out[i] = data[i] ^ key[i % key.count]`).
    public static func xor(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(!key.isEmpty, "XOR key must not be empty")
        return data.enumerated().map { i, b in b ^ key[i % key.count] }
    }
}

private extension String {
    func subclean(at offset: Int) -> Substring {
        let start = index(startIndex, offsetBy: offset)
        let end = index(startIndex, offsetBy: offset + 2)
        return self[start..<end]
    }
}
