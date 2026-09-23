import SwiftUI
@preconcurrency import AVFoundation
import ScaleKit

/// SRD-010 §3 — QR pairing parity with the official app: the watch shows a QR
/// (`…btname=stormcall_3_0610…mac=AA:BB:…`); scanning it resolves the watch
/// without a manual scan list. Payload parsing lives in ScaleKit
/// (`KahaProtocol.parsePairingQR`); this view handles the camera.
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
                    CameraPreview(session: scanner.session)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear { scanner.start(onFound: handle) }
                        .onDisappear { scanner.stop() }
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

/// Minimal metadata-output reader — one QR hit is all we need.
@MainActor
final class QRReader: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var configured = false
    private var running = false

    func start(onFound: @escaping (String) -> Void) {
        self.onFound = onFound
        if !configured {
            configure()
        }
        guard running, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
            Task { @MainActor in self.running = true }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
            Task { @MainActor in self.running = false }
        }
    }

    private var onFound: ((String) -> Void)?

    private func configure() {
        configured = true
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
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

/// UIViewControllerRepresentable wrapper over the capture session.
struct CameraPreview: UIViewControllerRepresentable {
    let session: AVCaptureSession

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = vc.view.bounds
            vc.view.layer.addSublayer(layer)
            context.coordinator.previewLayer = layer
        }
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        context.coordinator.previewLayer?.frame = vc.view.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
