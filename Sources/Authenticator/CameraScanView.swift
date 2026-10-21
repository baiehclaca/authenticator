#if os(macOS)
import AppKit
import SwiftUI

struct CameraScanView: View {
    /// Return nil to accept (sheet closes), or an error message to keep scanning.
    var onPayload: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan QR Code").font(.title2.bold())
            Text("Hold the QR code (for Google Authenticator: **Transfer accounts → Export accounts**) up to your Mac’s camera.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                switch scanner.state {
                case .running, .idle:
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
                        .frame(width: 220, height: 220)
                case .denied:
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("Camera access is turned off.")
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                case .unavailable(let reason):
                    VStack(spacing: 10) {
                        Image(systemName: "video.badge.exclamationmark").font(.largeTitle)
                        Text(reason)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 480, height: 360)

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.detectedPayload) { _, payload in
            guard let payload else { return }
            if let problem = onPayload(payload) {
                message = problem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scanner.resume() }
            } else {
                scanner.stop()
                dismiss()
            }
        }
    }
}
#endif
