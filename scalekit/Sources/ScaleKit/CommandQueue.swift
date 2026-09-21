import Foundation

/// Single-flight command queue — port of `FatScalePairWorker.commandCacheQueue`
/// + 3 s resend timer.
///
/// Commands are enqueued as pre-encoded frames; the queue writes frame 0, then
/// advances on each `onWriteComplete` (18-byte framing), and pops the command
/// when the device ACKs it. `tick()` drives resend/timeout.
public struct CommandQueue {
    public struct Entry {
        public let characteristic: UUID
        public let frames: [[UInt8]]
        var nextFrame = 0
        var writesSent = 0        // total writes issued for this entry
        var resends = 0

        public var pendingFrameCount: Int { max(0, frames.count - nextFrame) }
        public var sentFrameCount: Int { min(nextFrame, frames.count) }
        public var resendCount: Int { resends }

        init(characteristic: UUID, frames: [[UInt8]]) {
            self.characteristic = characteristic
            self.frames = frames
        }
    }

    private(set) var entries: [Entry] = []
    private let maxResends: Int

    public init(maxResends: Int = 3) {
        self.maxResends = maxResends
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var current: Entry? { entries.first }

    public var isWritePending: Bool {
        guard let e = entries.first else { return false }
        return e.nextFrame < e.frames.count
    }

    /// Enqueue a command payload (encoded by A6FrameCodec into frames).
    public mutating func enqueue(characteristic: UUID, payload: [UInt8], codec: A6FrameCodec, mac: String, xored: Bool) {
        let wire = codec.encodePacket(payload: payload, mac: mac, xored: xored)
        var frames: [[UInt8]] = []
        var offset = 0
        while offset < wire.count {
            let len = Int(wire[offset + 1])
            frames.append(Array(wire[offset..<(offset + 2 + len)]))
            offset += 2 + len
        }
        entries.append(Entry(characteristic: characteristic, frames: frames))
    }

    /// Frames the host must write right now (the pending write of the head entry).
    /// Empty means: nothing pending (waiting for ACK) or queue empty.
    public mutating func pendingWrite() -> (characteristic: UUID, frame: [UInt8])? {
        guard !entries.isEmpty else { return nil }
        guard entries[0].nextFrame < entries[0].frames.count else { return nil }
        entries[0].writesSent += 1
        let frame = entries[0].frames[entries[0].nextFrame]
        entries[0].nextFrame += 1
        return (entries[0].characteristic, frame)
    }

    /// One full write cycle of the head entry completed (all frames written).
    /// The head stays until its ACK arrives; the host arms the resend timer.
    public mutating func markWriteCycleComplete() {}

    /// Device ACK (ok) received for the head command → pop it.
    public mutating func popOnAck() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeFirst()
        return true
    }

    /// 3 s elapsed without ACK → re-issue the head command's frames.
    /// Returns false if the command exceeded its resend budget (caller aborts).
    public mutating func resend() -> Bool {
        guard !entries.isEmpty else { return false }
        entries[0].resends += 1
        entries[0].nextFrame = 0
        return entries[0].resends <= maxResends
    }
}
