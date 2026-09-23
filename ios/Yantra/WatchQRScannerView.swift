import SwiftUI
@preconcurrency import AVFoundation
import ScaleKit

/// SRD-010 §3 — QR pairing parity with the official app: the watch shows a QR
/// (`…btname=stormcall_3_0610…mac=AA:BB:…`); scanning it resolves the watch
/// without a manual scan list. Payload parsing lives in ScaleKit
/// (`KahaProtocol.parsePairingQR`); this view handles the camera.
///
/// Black-preview fix: camera access must be *requested* before building the
/// session — `AVCaptureDeviceInput(device:)` fails silently when authorization
/// is still `.notDetermined`, leaving an input-less session that renders black.
/// The preview now also attaches its layer in `viewDidLoad` with autoresizing
/// bounds tracking instead of a one-shot zero-frame layout pass.
struct WatchQRScannerView: View {
    /// Parsed pairing payload on success.
    var onResolved: (KahaProtocol.PairingQR) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRReader()
    @State private var manualMAC = ""
    @State private var showManual = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    switch scanner.status {
                    case .idle, .requesting:
                        Color.black
                            .overlay(ProgressView().tint(.white))
                    case .denied:
                        Color.black
                            .overlay(
                                VStack(spacing: 10) {
                                    Image(systemName: "video.slash.fill")
                                        .font(.largeTitle).foregroundStyle(.white)
                                    Text("Camera access is off for Yantra.")
                                        .foregroundStyle(.white)
                                    Button("Open Settings") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            )
                    case .running, .failed:
                        CameraPreview(session: scanner.session)
                    }
                    // Reticle
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: 260, height: 260)
                }
                .frame(maxHeight: 420)
                .overlay(alignment: .top) {
                    Text("Show the pairing QR on your watch")
                        .font(.headline)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .padding(.vertical, 6)
                }
                List {
                    Section {
                        Button(showManual ? "Hide manual MAC entry" : "Enter MAC manually") {
                            showManual.toggle()
                        }
                        if showManual {
                            TextField("AA:BB:CC:DD:EE:FF", text: $manualMAC)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .monospaced()
                            Button("Pair this watch") {
                                let digits = manualMAC.replacingOccurrences(of: ":", with: "")
                                if digits.count == 12,
                                   let qr = KahaProtocol.parsePairingQR("btname=stormcall&mac=\(digits)") {
                                    onResolved(qr)
                                    dismiss()
                                } else {
                                    errorText = "MAC must be 12 hex digits"
                                }
                            }
                        }
                    } header: {
                        Text("Fallback")
                    } footer: {
                        Text("The QR carries the watch name and MAC. Manual entry skips the camera when the code won't scan.")
                    }
                }
            }
            .navigationTitle("Scan watch QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Request authorization first; only start the session once granted.
                await scanner.start(onFound: handle)
            }
            .onDisappear { scanner.stop() }
        }
    }

    private func handle(_ text: String) {
        guard let qr = KahaProtocol.parsePairingQR(text) else {
            errorText = "Not a boAt pairing QR (btname=… expected)"
            return
        }
        onResolved(qr)
        dismiss()
    }
}

// MARK: - AVFoundation plumbing

/// Camera authorization + capture lifecycle. `start` must be awaited so the
/// permission dialog resolves before the session is configured.
@MainActor
final class QRReader: NSObject, ObservableObject {
    enum Status { case idle, requesting, running, denied, failed }

    @Published private(set) var status: Status = .idle
    let session = AVCaptureSession()
    private var configured = false
    private var onFound: ((String) -> Void)?

    func start(onFound: @escaping (String) -> Void) async {
        self.onFound = onFound
        // 1. Authorization — the missing piece behind the black preview.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            status = .requesting
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        default:
            status = .denied
            return
        }
        // 2. Configure once, off the main thread, then start running.
        if !configured { configure() }
        guard !session.inputs.isEmpty else {
            status = .failed
            return
        }
        guard !session.isRunning else {
            status = .running
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
                cont.resume()
            }
        }
        status = .running
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.sessionPreset = .high
    }
}

extension QRReader: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              obj.type == .qr, let value = obj.stringValue else { return }
        Task { @MainActor in
            self.onFound?(value)
        }
    }
}

/// UIViewControllerRepresentable wrapper whose preview layer tracks the view's
/// bounds (added in viewDidLoad, resized on layoutSubviews).
struct CameraPreview: UIViewControllerRepresentable {
    let session: AVCaptureSession

    final class PreviewVC: UIViewController {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer.frame = view.bounds
        }
    }

    func makeUIViewController(context: Context) -> PreviewVC {
        let vc = PreviewVC()
        vc.previewLayer.session = session
        return vc
    }

    func updateUIViewController(_ vc: PreviewVC, context: Context) {
        if vc.previewLayer.session !== session {
            vc.previewLayer.session = session
        }
        vc.previewLayer.frame = vc.view.bounds
    }
}
