import Foundation

/// Nordic-style DFU state machine for the scale's bootloader service
/// (1530/1531/1532) — port of the decompiled `FatScaleOtaWorker` workflow
/// (SRD-007).
///
/// The scale **enters DFU mode on its own** (device-triggered, advertising as
/// `LsD…`/`LsDfu…`); the host scans, connects to the open DFU service, and runs:
///
/// 1. enable `1531` notifications
/// 2. `START_DFU [0x01, binType]` on 1531 → `[0x10, 0x01, status]` response
/// 3. image size + checkModel(4B) + version(4B) + CRC16(LE) on `1532`
/// 4. `INIT_DFU [0x08, 6, 0]` on 1531
/// 5. `RECEIVE_FIRMWARE [0x03]` on 1531
/// 6. stream 20-byte packets on `1532`; after every 6th frame wait for the
///    `0x11` flow-resume notification (decompiled `MAX_FRAME_FOR_EACH_CONNECTION_INTERVAL = 6`)
/// 7. `VALIDATE [0x04]` → `[0x10, 0x04]` ack
/// 8. `ACTIVATE_AND_RESET [0x05]` → device reboots into the new image
///
/// Repeat per bin (BLE → SOC → WIFI) until the queue is empty.
/// This machine speaks the same `LinkAction`/`LinkEvent` dialect as
/// `PairStateMachine`/`SessionStateMachine`, so every host (a6host, Yantra)
/// can drive it with the plumbing it already has.
public struct DfuStateMachine {
    public enum Phase: Equatable {
        case idle
        case connecting
        case enablingNotify
        case startDfu(DfuImage.BinType)
        case writingImageInfo(DfuImage.BinType)
        case initDfu(DfuImage.BinType)
        case receiveFirmware(DfuImage.BinType)
        case streaming(DfuImage.BinType, sent: Int, total: Int)
        case validate(DfuImage.BinType)
        case activate(DfuImage.BinType)
        /// A bin was activated — the device reboots; the host must reconnect
        /// for the next bin (official worker's reconnect loop).
        case awaitingReconnect(remaining: Int)
        case done
        case failed(String)
    }

    public struct Progress: Equatable {
        public var phase: Phase
        /// 0...100 across the whole transfer.
        public var percent: Int
        public var binType: DfuImage.BinType?
    }

    /// Frames streamed between flow-control pauses (decompiled constant 6).
    public static let framesPerWindow = 6

    public private(set) var phase: Phase = .idle
    public let image: DfuImage
    /// Check-model string written with the image size (padded to 4 bytes with
    /// NULs by the official worker). Usually the device model, e.g. "LS213-B".
    public let checkModel: String

    private var binQueue: [DfuImage.BinImage] = []
    private var current: DfuImage.BinImage?
    private var sentPackets = 0
    private var framesSinceResume = 0
    private var paused = false

    public init(image: DfuImage, checkModel: String) {
        self.image = image
        self.checkModel = checkModel
        self.binQueue = image.bins
    }

    // MARK: Lifecycle

    public mutating func start() -> Output {
        phase = .connecting
        return Output(actions: [.connect(macOrIdentifier: "")], progress: progress)
    }

    public mutating func cancel() -> Output {
        phase = .failed("cancelled")
        return Output(actions: [.disconnect], progress: progress)
    }

    public var isTerminal: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    public var progress: Progress {
        let total = max(image.allBinSize, 1)
        let sentBytes = (image.allBinSize - binQueue.reduce(0) { $0 + $1.contentBytes })
            + (current.map { c in
                let totalPackets = c.packets.count
                let fraction = totalPackets > 0 ? Double(sentPackets) / Double(totalPackets) : 0
                return Int(fraction * Double(c.contentBytes))
            } ?? 0)
        let pct = phase == .done ? 100 : min(99, sentBytes * 100 / total)
        return Progress(phase: phase, percent: phase == .done ? 100 : pct,
                        binType: current?.type)
    }

    public struct Output {
        public var actions: [LinkAction] = []
        public var progress: Progress
        public var finished: Bool = false
    }

    // MARK: Events

    public mutating func handle(_ event: LinkEvent) -> Output {
        guard !isTerminal else { return Output(progress: progress) }
        switch event {
        case .connected:
            phase = .enablingNotify
            return Output(actions: [.discoverServices], progress: progress)

        case .servicesDiscovered:
            return Output(actions: [.enableNotify(characteristic: DfuGATT.controlPoint)],
                          progress: progress)

        case .notifyEnabled(let c) where c == DfuGATT.controlPoint:
            // First bin, or re-entry after the device rebooted between bins.
            return startNextBin()

        case .notifyData(let c, let data) where c == DfuGATT.controlPoint:
            return handleNotification(DfuNotification.parse(data))

        case .disconnected:
            if phase == .done { return Output(progress: progress, finished: true) }
            if case .awaitingReconnect = phase {
                return Output(progress: progress)   // device rebooting — wait for reconnect
            }
            phase = .failed("disconnected during \(phase)")
            return Output(progress: progress)

        case .commandTimedOut:
            phase = .failed("DFU control-point timeout")
            return Output(actions: [.disconnect], progress: progress)

        default:
            return Output(progress: progress)
        }
    }

    // MARK: Steps (decompiled handleProtocolWorkingFlow)

    private mutating func startNextBin() -> Output {
        guard let bin = binQueue.first else {
            phase = .done
            return Output(progress: progress, finished: true)
        }
        current = bin
        sentPackets = 0
        framesSinceResume = 0
        paused = false
        phase = .startDfu(bin.type)
        return Output(actions: [.write(characteristic: DfuGATT.controlPoint,
                                       data: [DfuOpcode.startDfu, bin.type.code])],
                      progress: progress)
    }

    private mutating func handleNotification(_ n: DfuNotification) -> Output {
        switch (phase, n) {
        // START_DFU acknowledged → write image info to the packet characteristic.
        case (.startDfu(let type), .startResponse):
            phase = .writingImageInfo(type)
            return Output(actions: [.write(characteristic: DfuGATT.packet,
                                           data: imageInfo(type: type))],
                          progress: progress)

        // Image-info write is acked by the START notification when the worker
        // is already in INIT phase — the decompiled worker treats
        // `onImageSizeResponse` as the trigger for INIT_DFU.
        case (.writingImageInfo(let type), .startResponse):
            phase = .initDfu(type)
            return Output(actions: [.write(characteristic: DfuGATT.controlPoint,
                                           data: [DfuOpcode.initDfu, 6, 0])],
                          progress: progress)

        case (.initDfu(let type), .startResponse):
            phase = .receiveFirmware(type)
            return Output(actions: [.write(characteristic: DfuGATT.controlPoint,
                                           data: [DfuOpcode.receiveFirmware])],
                          progress: progress)

        case (.receiveFirmware(let type), .startResponse):
            phase = .streaming(type, sent: 0, total: current?.packets.count ?? 0)
            return streamWindow()

        case (.streaming, .flowResume):
            paused = false
            return streamWindow()

        case (.streaming, .receiveComplete):
            guard let type = current?.type else { break }
            phase = .validate(type)
            return Output(actions: [.write(characteristic: DfuGATT.controlPoint,
                                           data: [DfuOpcode.validate])],
                          progress: progress)

        case (.validate(let type), .validateComplete):
            phase = .activate(type)
            return Output(actions: [.write(characteristic: DfuGATT.controlPoint,
                                           data: [DfuOpcode.activateAndReset])],
                          progress: progress)

        case (.activate, .validateComplete):
            // Activation acked — pop the finished bin. More bins: the device
            // reboots and the host reconnects (awaitingReconnect tolerates the
            // disconnect). Last bin: done, device boots the new image.
            if !binQueue.isEmpty { binQueue.removeFirst() }
            if binQueue.isEmpty {
                phase = .done
                return Output(progress: progress, finished: true)
            }
            phase = .awaitingReconnect(remaining: binQueue.count)
            return Output(progress: progress)

        case (_, .unknown(let raw)):
            phase = .failed("unexpected DFU notification: "
                + raw.map { String(format: "%02X", $0) }.joined())
            return Output(progress: progress)

        default:
            break
        }
        return Output(progress: progress)
    }

    /// Emits up to `framesPerWindow` packet writes in one batch (the host's BLE
    /// stack buffers/paces them); after a full window the machine pauses until
    /// the device's `0x11` flow-resume notification — decompiled
    /// `maxFrameIndex % 6 == 0 && !isResponseForNext` semantics.
    private mutating func streamWindow() -> Output {
        guard let bin = current, !paused else { return Output(progress: progress) }
        var actions: [LinkAction] = []
        while sentPackets < bin.packets.count, framesSinceResume < Self.framesPerWindow {
            actions.append(.write(characteristic: DfuGATT.packet, data: bin.packets[sentPackets]))
            sentPackets += 1
            framesSinceResume += 1
        }
        guard !actions.isEmpty else { return Output(progress: progress) }
        phase = .streaming(bin.type, sent: sentPackets, total: bin.packets.count)
        if sentPackets < bin.packets.count {
            paused = true             // window full — wait for flowResume
            framesSinceResume = 0
        }
        return Output(actions: actions, progress: progress)
    }

    /// Image size(4B LE) + checkModel(padded to 4B) + version(4B) + CRC16(2B LE)
    /// — decompiled case 4.
    private func imageInfo(type: DfuImage.BinType) -> [UInt8] {
        guard let bin = current else { return [] }
        var data: [UInt8] = []
        func le32(_ v: Int) -> [UInt8] {
            [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
             UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
        }
        data += le32(bin.size)
        var model = Array(checkModel.utf8)
        while model.count < 4 { model.append(0) }
        data += Array(model.prefix(4))
        data += Array(bin.version.utf8.prefix(4))
        if bin.version.utf8.count < 4 {
            data += [UInt8](repeating: 0, count: 4 - bin.version.utf8.count)
        }
        data += [UInt8(truncatingIfNeeded: bin.crc16), UInt8(truncatingIfNeeded: bin.crc16 >> 8)]
        return data
    }
}
