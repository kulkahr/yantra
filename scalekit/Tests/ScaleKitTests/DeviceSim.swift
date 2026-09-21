import Foundation
@testable import ScaleKit

/// Simulates the realme Smart Scale firmware's radio behavior for replay tests:
/// - app→device frames are XOR-obfuscated (fw ≥ 1.4.0.25), single-frame (≤18 B)
/// - device→app data frames are XOR-obfuscated too; multi-frame packets carry
///   CRC32(plaintext) appended BEFORE the whole packet is XORed
///   (verified wire convention — see PROTOCOL_ANALYSIS.md §3)
/// - ACKs are `[00 01 status]` on A625 with the status byte XOR MAC[0]
struct DeviceSimulator {
    let mac: String
    let macb: [UInt8]

    init(mac: String) {
        self.mac = mac
        self.macb = A6Obfuscation.macBytes(mac)
    }

    /// Wire frames of a device→app command as the firmware sends them.
    /// `body` excludes the 2-byte command header.
    func command(_ cmd: UInt16, body: [UInt8]) -> [[UInt8]] {
        packet(payload: A6Bytes.from(short: cmd) + body)
    }

    /// Wire frames of a `0x4802` weight-record packet.
    func recordPacket(remain: Int, flags: UInt32, kg: Double) -> [[UInt8]] {
        var body: [UInt8] = []
        body += A6Bytes.from(short: UInt16(remain))
        body += A6Bytes.from(int: flags)
        body += A6Bytes.from(short: UInt16((kg * 100).rounded()))
        return command(0x4802, body: body)
    }

    /// ACK bytes as delivered on the A625 characteristic (single notify).
    func ackData() -> [UInt8] {
        var status: UInt8 = 0x01
        status ^= macb[0]
        return [0x00, 0x01, status]
    }

    /// Device→app packet encoding (firmware convention):
    /// XOR(plaintext ‖ crc32(plaintext)) chunked into ≤18-byte frames.
    private func packet(payload: [UInt8]) -> [[UInt8]] {
        var full = payload
        if full.count > 18 {
            full += CRC32.checksumBytes(payload)
        }
        let xoredFull = A6Obfuscation.xor(full, key: macb)
        var chunks: [[UInt8]] = []
        var i = 0
        while i < xoredFull.count {
            chunks.append(Array(xoredFull[i..<min(i + 18, xoredFull.count)]))
            i += 18
        }
        return chunks.enumerated().map { serial, chunk in
            [UInt8((chunks.count << 4) | serial), UInt8(chunk.count)] + chunk
        }
    }
}
