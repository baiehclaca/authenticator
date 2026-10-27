#if os(macOS)
import AVFoundation
import AppKit
import SwiftUI
import Vision

/// Live QR scanning with the Mac's camera (built-in, external or Continuity
/// Camera). Frames are analysed on-device with Vision; nothing leaves the Mac.
final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case idle
        case running
        case denied
        case unavailable(String)
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .idle
    /// Set (on the main thread) when an `otpauth…` QR code is seen.
    @Published var detectedPayload: String?

    private let queue = DispatchQueue(label: "com.baiehclaca.authenticator.camera")
    private var lastAnalysis = Date.distantPast // accessed on `queue` only
    private var isConfigured = false             // accessed on `queue` only
    /// True while a detected payload awaits a decision; frames are skipped meanwhile.
    private var hasPendingPayload = false        // accessed on `queue` only
    /// Whether the scan view still wants the camera (main thread only). Guards the
    /// async permission callback from starting the camera after the sheet closed.
    private var wantsRunning = false

    func start() {
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !granted {
                        self.state = .denied
                    } else if self.wantsRunning {
                        self.configureAndRun()
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        wantsRunning = false
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Resume scanning after a payload was rejected.
    func resume() {
        detectedPayload = nil
        queue.async { [weak self] in self?.hasPendingPayload = false }
    }

    deinit {
        // Never leave the camera (and its green light) running once the scanner is gone.
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndRun() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                if let problem = self.configure() {
                    DispatchQueue.main.async { self.state = .unavailable(problem) }
                    return
                }
                self.isConfigured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.state = .running }
        }
    }

    /// Returns an error description, or nil on success.
    private func configure() -> String? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = AVCaptureDevice.default(for: .video) ?? discovery.devices.first else {
            return "No camera was found."
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            guard session.canAddInput(input) else { return "The camera couldn’t be used." }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return "The camera output couldn’t be configured." }
            session.addOutput(output)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (runs on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Don't run Vision while a found code is waiting to be accepted/rejected.
        guard !hasPendingPayload else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) > 0.15 else { return }
        lastAnalysis = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil else { return }
        let payload = (request.results ?? [])
            .compactMap { $0.payloadStringValue }
            .first { $0.lowercased().hasPrefix("otpauth") }
        guard let payload else { return }
        hasPendingPayload = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.detectedPayload == nil else { return }
            self.detectedPayload = payload
        }
    }
}

/// AVCaptureVideoPreviewLayer hosted in SwiftUI.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
#endif
