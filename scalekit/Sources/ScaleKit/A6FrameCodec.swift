import Foundation

/// Transport-layer frame codec — ports of:
///  - `A6ProtocolParser.generateResponsePackage` (encode)
///  - `DeviceDataPackage.formBytes` (frame decode)
///  - `DeviceDataPackage.verify` (CRC check on reassembled packets)
///
/// Wire format per frame: `[ (frameCount<<4)|frameSerial, payloadLen, payload… ]`
/// payload ≤ 18 bytes; whole-payload XOR with MAC when firmware ≥ 1.4.0.25;
/// packets of more than one frame carry an 8-hex-char CRC32 suffix.
public struct A6FrameCodec {

    public init() {}

    // MARK: - Encode (app → device)

    /// Encode a full command payload (including its 2-byte command header) into
    /// one or more wire frames. `xored` per `A6Security.isXorVariant(firmwareVersion:)`.
    public func encodePacket(payload: [UInt8], mac: String, xored: Bool) -> [UInt8] {
        var data = payload
        let macb = A6Obfuscation.macBytes(mac)
        if xored && !macb.isEmpty {
            data = A6Obfuscation.xor(data, key: macb)
        }
        let hex = A6Hex.encode(data)
        var buf = hex
        if hex.count > 36 {                       // > 1 frame → append CRC of the (xored) payload
            buf += CRC32.checksumString(data)
        }
        let total = buf.count
        var out: [UInt8] = []
        var offset = 0
        var serial = 0
        while offset < total {
            let frameHexLen = min(36, total - offset)          // hex chars in this frame
            let count = (total + 35) / 36                      // total frames
            out.append(UInt8((count << 4) | serial))
            out.append(UInt8(frameHexLen / 2))
            out += A6Hex.decode(String(buf.dropFirst(offset).prefix(frameHexLen)))
            offset += frameHexLen
            serial += 1
        }
        return out
    }

    // MARK: - Decode (device → app)

    /// One parsed wire frame.
    public struct Frame {
        public let count: Int          // total frames in packet (0 = pure ACK)
        public let serial: Int         // this frame's index (0 = header)
        public let length: Int         // payload byte length
        /// 4-hex-char packet command — only valid on the header frame of a multi-
        /// frame packet (decompiled formBytes only fills it when serial==0 && count!=0).
        public let commandHex: String
        /// XOR-decoded payload bytes.
        public let payload: [UInt8]
    }

    /// Decode a single wire frame. Returns nil for frames too short to be valid.
    public func decodeFrame(_ wire: [UInt8], mac: String, xored: Bool) -> Frame? {
        guard wire.count > 2 else { return nil }
        let count = Int(wire[0] >> 4) & 0x0F
        let serial = Int(wire[0]) & 0x0F
        let length = Int(wire[1]) & 0xFF

        var commandHex = ""
        var payload: [UInt8] = []
        let macb = A6Obfuscation.macBytes(mac)

        if length + 2 <= wire.count {
            if serial == 0 && count != 0 {
                var head = Array(wire[2..<4])
                if xored && !macb.isEmpty { head = A6Obfuscation.xor(head, key: macb) }
                commandHex = A6Hex.encode(head)
            }
            var body = Array(wire[2..<(2 + length)])
            if xored && !macb.isEmpty { body = A6Obfuscation.xor(body, key: macb) }
            payload = body
        }
        return Frame(count: count, serial: serial, length: length,
                     commandHex: commandHex, payload: payload)
    }

    /// Reassembler for multi-frame packets (port of the
    /// `A6ProtocolParser.frameCache` logic + `DeviceDataPackage.verify`).
    ///
    /// PROTOCOL ASYMMETRY (from decompiled source — verify against live device in E2):
    ///  - app→device encoder (`generateResponsePackage`): CRC over the **XORed** payload
    ///  - device→app verifier (`verify()`): CRC over the **plaintext** payload
    /// Hence the CRC policy must match the packet's origin direction.
    public struct PacketAssembler {
        public enum CRCPolicy {
            /// device→app: CRC computed over plaintext (decompiled `verify()`)
            case overPlaintext
            /// app→device: CRC computed over XOR-obfuscated payload (decompiled `generateResponsePackage`)
            case overObfuscated
        }

        private var frames: [Int: [UInt8]] = [:]
        private var expectedCount = 0
        private var headerCommand = ""
        private let mac: String
        private let xored: Bool
        private let crcPolicy: CRCPolicy

        public init(mac: String, xored: Bool, crcPolicy: CRCPolicy = .overPlaintext) {
            self.mac = mac
            self.xored = xored
            self.crcPolicy = crcPolicy
        }

        public mutating func reset() {
            frames.removeAll()
            expectedCount = 0
            headerCommand = ""
        }

        /// Feed one decoded frame. Returns the complete packet payload
        /// (command header + data, CRC verified & stripped) when done.
        public mutating func ingest(_ frame: Frame) -> Result<[UInt8], A6Error>? {
            switch frame.count {
            case 0:
                return .success(frame.payload)      // ACK packet — pass through
            default:
                if frames.isEmpty {
                    expectedCount = frame.count
                    headerCommand = frame.commandHex
                }
                frames[frame.serial] = frame.payload
                guard frames.count == expectedCount else { return nil }

                // reassemble by serial order
                var data: [UInt8] = []
                for i in 0..<expectedCount {
                    guard let part = frames[i] else { return .failure(.missingFrame(i)) }
                    data += part
                }
                frames.removeAll()

                if expectedCount > 1 {
                    // last 4 bytes = CRC32 of everything before them
                    guard data.count > 4 else { return .failure(.packetTooShort) }
                    let body = Array(data.dropLast(4))
                    let crc = Array(data.suffix(4))
                    var crcInput = body
                    if crcPolicy == .overObfuscated && xored {
                        crcInput = A6Obfuscation.xor(body, key: A6Obfuscation.macBytes(mac))
                    }
                    guard CRC32.checksumBytes(crcInput) == crc else {
                        return .failure(.crcMismatch(expected: A6Hex.encode(crc),
                                                     actual: A6Hex.encode(CRC32.checksumBytes(crcInput))))
                    }
                    return .success(body)
                }
                return .success(data)
            }
        }
    }
}

public enum A6Error: Error, Equatable {
    case missingFrame(Int)
    case crcMismatch(expected: String, actual: String)
    case packetTooShort
    case invalidFrame
}
