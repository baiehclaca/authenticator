import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit
import Vision
import AuthenticatorCore

/// Finds QR code payloads in images and on screen.
enum QRScanner {
    enum ScanError: LocalizedError {
        case screenRecordingPermissionNeeded
        case noDisplays

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionNeeded:
                "Authenticator needs Screen Recording permission to scan the screen. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again (you may need to relaunch the app)."
            case .noDisplays:
                "No displays were found to scan."
            }
        }
    }

    /// All QR payload strings found in `image` (Vision, with a Core Image fallback).
    static func payloads(in image: CGImage) -> [String] {
        var found: [String] = []
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform([request])) != nil {
            found = (request.results ?? []).compactMap { $0.payloadStringValue }
        }
        if found.isEmpty {
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let features = detector?.features(in: CIImage(cgImage: image)) ?? []
            found = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Captures every display (excluding this app's own windows) and returns QR payloads found.
    static func scanScreens() async throws -> [String] {
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time and adds the app to the privacy list.
            _ = CGRequestScreenCaptureAccess()
            throw ScanError.screenRecordingPermissionNeeded
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScanError.screenRecordingPermissionNeeded
        }
        guard !content.displays.isEmpty else { throw ScanError.noDisplays }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == myPID }

        var found: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            found += Self.payloads(in: image)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }
}

/// Turns QR payloads into accounts plus a user-facing error message.
enum QRImport {
    struct Outcome {
        var accounts: [OTPAccount] = []
        var error: String?
        var needsScreenPermission = false
    }

    static func fromImages(_ images: [CGImage]) async -> Outcome {
        guard !images.isEmpty else { return Outcome(error: "That image couldn't be opened.") }
        let payloads = await Task.detached(priority: .userInitiated) {
            images.flatMap { QRScanner.payloads(in: $0) }
        }.value
        return outcome(for: payloads)
    }

    static func fromFiles(_ urls: [URL]) async -> Outcome {
        let images = urls.compactMap { QRScanner.cgImage(from: $0) }
        return await fromImages(images)
    }

    static func fromScreen() async -> Outcome {
        do {
            return outcome(for: try await QRScanner.scanScreens(), onScreen: true)
        } catch QRScanner.ScanError.screenRecordingPermissionNeeded {
            return Outcome(error: QRScanner.ScanError.screenRecordingPermissionNeeded.errorDescription,
                           needsScreenPermission: true)
        } catch {
            return Outcome(error: error.localizedDescription)
        }
    }

    static func outcome(for payloads: [String], onScreen: Bool = false) -> Outcome {
        var accounts: [OTPAccount] = []
        var firstError: Error?
        for payload in payloads {
            do {
                accounts += try OTPAuthURI.parseAny(payload)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if accounts.isEmpty {
            if payloads.isEmpty {
                return Outcome(error: onScreen
                    ? "No QR code found on screen. Make sure the code is fully visible and not covered by this window."
                    : "No QR code found in the image.")
            }
            return Outcome(error: (firstError?.localizedDescription).map { "Found a QR code, but: \($0)" }
                ?? "The QR code isn't an authenticator code.")
        }
        return Outcome(accounts: accounts)
    }
}

/// Generates a QR code image (for showing an account's setup code / transferring to a phone).
enum QRGenerator {
    static func image(for string: String, scale: CGFloat = 10) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}
