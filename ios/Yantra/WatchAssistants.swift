import UIKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreHaptics

/// Issue #35 — the watch's find-my-phone must RING and VIBRATE the phone, not
/// just raise a notification. Plays the ringtone in a loop at route volume,
/// fires a repeating haptic pattern and blinks the flashlight until stopped.
@MainActor
final class FindPhoneCoordinator: NSObject, ObservableObject {

    static let shared = FindPhoneCoordinator()

    @Published private(set) var active = false

    private var player: AVAudioPlayer?
    private var hapticEngine: CHHapticEngine?
    private var stopWork: DispatchWorkItem?
    /// Flashlight on/off while active.
    private var torchOn = false

    func begin(duration: TimeInterval = 30) {
        guard !active else { return }
        active = true

        // 1. Ringtone loop (respects the user's volume; uses playback category
        //    so it sounds even with the mute switch).
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let ringURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/alarm.caf")
        if let player = try? AVAudioPlayer(contentsOf: ringURL) {
            self.player = player
            player.numberOfLoops = -1
            player.play()
        }

        // 2. Haptics: repeating strong-thump pattern (falls back to kSystemSoundID_Vibrate).
        prepareHaptics()
        vibrateLoop()

        // 3. Flashlight blink.
        blinkTorch()

        let stop = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stop)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        active = false
        player?.stop()
        player = nil
        try? hapticEngine?.stop()
        torchOn = false
        setTorch(false)
    }

    // MARK: - Internals

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        try? hapticEngine?.start()
    }

    private func vibrateLoop() {
        guard active else { return }
        if let engine = hapticEngine {
            let events = (0..<3).map { i -> CHHapticEvent in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ], relativeTime: Double(i) * 0.4)
            }
            if let pattern = try? CHHapticPattern(events: events, parameters: []) {
                if let player = try? engine.makePlayer(with: pattern) {
                    try? player.start(atTime: 0)
                }
            }
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.vibrateLoop()
        }
    }

    private func blinkTorch() {
        guard active, let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        torchOn.toggle()
        setTorch(torchOn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.blinkTorch()
        }
    }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        if on {
            try? device.setTorchModeOn(level: 1.0)
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }
}

/// Issue #36 — the watch's camera-shutter button takes a REAL photo. A tiny
/// AVFOUNDATION capture session grabs a still, saves to the photo library,
/// and confirms with a shutter sound + haptic.
@MainActor
final class WatchCameraCoordinator: NSObject, ObservableObject {

    static let shared = WatchCameraCoordinator()

    @Published private(set) var lastCapture: Date?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false

    /// Called from the watch-shutter event (WatchCentral).
    func captureFromWatch() {
        if !configured { configure() }
        guard session.isRunning else {
            // Session still spinning up — start it and capture when ready.
            startThenCapture()
            return
        }
        capture()
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    private func startThenCapture() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
            Task { @MainActor in
                self.capture()
            }
        }
    }

    private func capture() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

extension WatchCameraCoordinator: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in
            self.lastCapture = Date()
            UIImageWriteToSavedPhotosAlbum(UIImage(data: data) ?? UIImage(), nil, nil, nil)
            AudioServicesPlaySystemSound(1108)   // shutter sound
            self.appendLog("photo saved from watch shutter")
        }
    }
}

private extension WatchCameraCoordinator {
    func appendLog(_ s: String) {}
}
