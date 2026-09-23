import Foundation

/// Lifesense OTA firmware-container parser — literal port of the decompiled
/// `OtaHeader` / `BinType` / `BinInfo` classes (SRD-007).
///
/// File layout (all multi-byte fields BIG-endian unless noted):
///
/// | offset | size | field |
///|--------|------|-------|
/// | 0      | 4    | magic (ASCII) |
/// | 4      | 4    | container version (ASCII) |
/// | 8      | 4    | total payload size |
/// | 12     | 4    | creation UTC |
/// | 16     | 16   | container MD5 (ASCII hex) |
/// | 32     | 32   | BLE bin descriptor (BinType.ble, code 4) |
/// | 64     | 32   | SOC bin descriptor (BinType.soc, code 8) |
/// | 96     | 32   | WIFI bin descriptor (BinType.wifi, code 9) |
///
/// Each bin descriptor: version(4B ASCII) · size(4B) · flash address(4B) ·
/// crc16(4B, only the low 2 bytes are transmitted) · md5(16B ASCII) — followed
/// (in the file, at the descriptor's flash address) by the bin content.
/// The transport appends the CRC16 (little-endian, 4 bytes) after the bin
/// content and splits everything into 20-byte DFU packets.
public struct DfuImage: Equatable {
    public enum BinType: String, CaseIterable, Codable {
        case ble = "BLE"
        case soc = "SOC"
        case wifi = "WIFI"

        /// Wire code written into the START_DFU command (`[0x01, code]`).
        public var code: UInt8 {
            switch self {
            case .ble: return 4
            case .soc: return 8
            case .wifi: return 9
            }
        }

        /// Offset of this type's descriptor within the container.
        public var descriptorOffset: Int {
            switch self {
            case .ble: return 32
            case .soc: return 64
            case .wifi: return 96
            }
        }
    }

    public struct BinImage: Equatable {
        public var type: BinType
        public var version: String        // 4 ASCII bytes
        public var size: Int              // content size in bytes
        public var address: Int           // flash address == content offset in file
        public var crc16: Int             // as stored (4-byte field; low 2 bytes on the wire)
        public var md5: String
        /// Content + little-endian CRC16, split into 20-byte DFU packets
        /// (last packet carries the remainder).
        public var packets: [[UInt8]]

        public var contentBytes: Int { packets.reduce(0) { $0 + $1.count } }
    }

    public var magic: String
    public var version: String
    public var size: Int
    public var createUtc: Int
    public var md5: String
    public var bins: [BinImage]        // descriptors with address != 0, in BLE/SOC/WIFI order

    /// Total transport size (bin contents + CRCs) — drives progress fractions.
    public var allBinSize: Int { bins.reduce(0) { $0 + $1.contentBytes } }

    // MARK: Parsing

    public enum ParseError: Error, Equatable {
        case tooSmall(Int)          // actual byte count
        case badMagic(String)
        case emptyImage             // no bin descriptor with address != 0
    }

    /// Parses and packetizes a `.bin` OTA container.
    public static func parse(_ data: [UInt8]) throws -> DfuImage {
        guard data.count >= 32 else { throw ParseError.tooSmall(data.count) }
        func str(_ offset: Int, _ len: Int) -> String {
            String(bytes: data[offset..<min(offset + len, data.count)]
                .filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
        }
        func be(_ offset: Int) -> Int {
            A6Bytes.toInt(Array(data[offset..<offset + 4]), at: 0)
        }
        let magic = str(0, 4)
        guard !magic.isEmpty else { throw ParseError.badMagic(magic) }

        var bins: [BinImage] = []
        for type in BinType.allCases {
            let o = type.descriptorOffset
            guard data.count >= o + 32 else { continue }
            let version = str(o, 4)
            let size = be(o + 4)
            let address = be(o + 8)
            let crc16 = be(o + 12)
            let md5 = str(o + 16, 16)
            guard address != 0, size > 0, address + size <= data.count else { continue }
            bins.append(try packetize(type: type, version: version, size: size,
                                      address: address, crc16: crc16, md5: md5,
                                      file: data))
        }
        guard !bins.isEmpty else { throw ParseError.emptyImage }
        return DfuImage(magic: magic, version: str(4, 4), size: be(8), createUtc: be(12),
                        md5: str(16, 16), bins: bins)
    }

    /// Port of `BinType.createBinInfo`: content + LE(crc16) split into 20-byte packets.
    static func packetize(type: BinType, version: String, size: Int, address: Int,
                          crc16: Int, md5: String, file: [UInt8]) throws -> BinImage {
        var stream = Array(file[address..<address + size])
        // intToLittleEndianBytes(crc16) — full 4 bytes appended (decompiled parity).
        stream += [
            UInt8(truncatingIfNeeded: crc16),
            UInt8(truncatingIfNeeded: crc16 >> 8),
            UInt8(truncatingIfNeeded: crc16 >> 16),
            UInt8(truncatingIfNeeded: crc16 >> 24),
        ]
        var packets: [[UInt8]] = []
        var i = 0
        while i + 20 < stream.count {
            packets.append(Array(stream[i..<i + 20]))
            i += 20
        }
        if i < stream.count { packets.append(Array(stream[i...])) }
        return BinImage(type: type, version: version, size: size, address: address,
                        crc16: crc16, md5: md5, packets: packets)
    }
}

/// DFU GATT constants (`IDeviceServiceProfiles`) — 1531 already exists in
/// `GATTPlus.otaData`; the rest live here to keep the DFU stack self-contained.
public enum DfuGATT {
    public static let service      = UUID(uuidString: "00001530-1212-EFDE-1523-785FEABCD123")!
    public static let controlPoint = GATTPlus.otaData   // 1531 write + notify
    public static let packet       = UUID(uuidString: "00001532-1212-EFDE-1523-785FEABCD123")!
    public static let version      = UUID(uuidString: "00001534-1212-EFDE-1523-785FEABCD123")!
}

/// Control-point opcodes written to `1531` (`FatScaleOtaWorker`).
public enum DfuOpcode {
    static let startDfu: UInt8 = 0x01          // payload [0x01, binTypeCode]
    static let initDfu: UInt8 = 0x08           // payload [0x08, 6, 0]
    static let receiveFirmware: UInt8 = 0x03
    static let validate: UInt8 = 0x04
    static let activateAndReset: UInt8 = 0x05
}

/// Device → app notifications on `1531`:
/// - `[0x10, op, status…]` — response to START (op 1: status byte), and
///   completion signals for RECEIVE (op 3) / VALIDATE (op 4)
/// - `[0x11, …]` — flow control: "send next frames" (resumes a paused stream)
public enum DfuNotification: Equatable {
    case startResponse(status: UInt8)
    case receiveComplete
    case validateComplete
    case flowResume
    case unknown([UInt8])

    public static func parse(_ data: [UInt8]) -> DfuNotification {
        guard let b0 = data.first else { return .unknown(data) }
        switch b0 {
        case 0x10:
            let op = data.count > 1 ? data[1] : 0
            switch op {
            case 1: return .startResponse(status: data.count > 2 ? data[2] : 0)
            case 3: return .receiveComplete
            case 4: return .validateComplete
            default: return .unknown(data)
            }
        case 0x11: return .flowResume
        default: return .unknown(data)
        }
    }
}
