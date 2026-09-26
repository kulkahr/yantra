import UIKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreHaptics
import MediaPlayer

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
        hapticEngine?.stop()
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
/// AVFoundation capture session grabs a still, saves to the photo library,
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

    /// QF13 (audit #20): pre-heat the session when the watch announces the
    /// camera remote (`.cameraEnter` event) — the shutter event usually
    /// follows within a second, and a cold `startRunning()` eats most of
    /// that budget, so the first watch-triggered shot could miss the moment.
    /// Idempotent: configuring twice or starting a running session is a no-op.
    func warmUp() {
        if !configured { configure() }
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
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

/// QF12 (audit #19) — the watch's transport keys (play/pause/next/prev/volume)
/// drive the phone's media playback instead of just logging. Dispatch mirrors
/// what the decompiled app does with its `MediaButtonReceiver` (Android
/// `dispatchMediaKeyEvent`); on iOS the public surface is the app's
/// `MPRemoteCommandCenter` + `MPVolumeView`, so:
/// - play/pause/next/prev go through `MPRemoteCommandCenter` — effective when
///   Yantra is the now-playing app (e.g. the audio screens it hosts);
/// - volume steps ride a hidden `MPVolumeView` slider (the standard public
///   way to move system volume).
@MainActor
final class MusicRemoteCoordinator: ObservableObject {

    static let shared = MusicRemoteCoordinator()

    private var volumeView: MPVolumeView?

    /// Routes one watch-initiated control event onto the phone's media session.
    func apply(_ event: KahaProtocol.WatchControlEvent) {
        let center = MPRemoteCommandCenter.shared()
        switch event {
        case .musicPlay:
            if center.togglePlayPauseCommand.isEnabled {
                center.togglePlayPauseCommand.sendCommand(nil)
            } else {
                center.playCommand.sendCommand(nil)
            }
        case .musicPause:
            if center.togglePlayPauseCommand.isEnabled {
                center.togglePlayPauseCommand.sendCommand(nil)
            } else {
                center.pauseCommand.sendCommand(nil)
            }
        case .musicNext:
            center.nextTrackCommand.sendCommand(nil)
        case .musicPrevious:
            center.previousTrackCommand.sendCommand(nil)
        case .volumeUp:
            nudgeSystemVolume(+1.0 / 16.0)
        case .volumeDown:
            nudgeSystemVolume(-1.0 / 16.0)
        case .findMyPhone, .cameraEnter, .cameraCapture,
             .callReject, .callMute:
            break   // not a music event
        }
    }

    /// Public-API system-volume nudge via a hidden MPVolumeView slider
    /// (AVAudioSession.outputVolume is read-only without this workaround).
    private func nudgeSystemVolume(_ delta: Float) {
        let view: MPVolumeView
        if let v = volumeView {
            view = v
        } else {
            view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
            // Watch events usually arrive while the app is backgrounded (no key
            // window) — a detached UIWindow is the standard host for the hidden
            // slider; it still drives system volume.
            let host = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
            host.addSubview(view)
            volumeView = view
        }
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let current = AVAudioSession.sharedInstance().outputVolume
        slider.value = max(0, min(1, current + delta))
    }
}
