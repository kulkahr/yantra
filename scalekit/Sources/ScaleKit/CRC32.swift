import Foundation

/// CRC-32 exactly as used by the Lifesense A6 protocol
/// (port of `DataUtils.init_crc_table` + `DataUtils.crc32`):
/// reflected polynomial 0xEDB88320, **init 0**, **no final XOR**.
/// (This is NOT zlib CRC-32, which uses init/xorout 0xFFFFFFFF.)
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var j = UInt32(i)
            for _ in 0..<8 {
                j = (j & 1) == 1 ? (j >> 1) ^ 0xEDB88320 : j >> 1
            }
            return j
        }
    }()

    /// CRC of raw bytes → UInt32.
    public static func checksum(_ data: [UInt8]) -> UInt32 {
        var j: UInt32 = 0
        for b in data {
            j = (j >> 8) ^ table[Int((UInt32(b) ^ j) & 0xFF)]
        }
        return j
    }

    /// Port of `DataUtils.get_crc32_string`: 8 uppercase hex chars, zero-padded.
    public static func checksumString(_ data: [UInt8]) -> String {
        String(format: "%08X", checksum(data))
    }

    /// Big-endian CRC bytes (as appended to packet hex).
    public static func checksumBytes(_ data: [UInt8]) -> [UInt8] {
        let v = checksum(data)
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
