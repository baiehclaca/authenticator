import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
import AuthenticatorCore

enum SettingsKey {
    static let requireUnlock = "requireUnlock"
    static let clearClipboardSeconds = "clearClipboardSeconds"
    static let showMenuBarExtra = "showMenuBarExtra"
}

/// Opens the "Add Account" sheet in a given mode, optionally pre-filled.
struct AddRequest: Identifiable {
    let id = UUID()
    var mode: AddMode
    var accounts: [OTPAccount] = []
    var text: String = ""
    var message: String? = nil
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let keychainService = "org.sinoussi.authenticator"

    @Published private(set) var vault = AccountVault()
    @Published var isLocked: Bool
    @Published var addRequest: AddRequest?
    @Published var alert: AppAlert?
    @Published var banner: String?
    @Published var isScanningScreen = false

    private let store = KeychainStore(service: AppModel.keychainService, account: "vault")
    /// False if the keychain item exists but couldn't be read: never overwrite it then.
    private var canSave = true
    private var observers: [NSObjectProtocol] = []
    private var bannerTask: Task<Void, Never>?

    var accounts: [OTPAccount] { vault.accounts }
    var requireUnlock: Bool { UserDefaults.standard.bool(forKey: SettingsKey.requireUnlock) }

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.clearClipboardSeconds: 30,
            SettingsKey.showMenuBarExtra: true,
            SettingsKey.requireUnlock: false,
        ])
        isLocked = UserDefaults.standard.bool(forKey: SettingsKey.requireUnlock)
        load()

        let lockHandler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lockHandler))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lockHandler))
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockHandler))
    }

    // MARK: - Persistence

    func load() {
        do {
            if let data = try store.read() {
                vault = try AccountVault.decode(data)
            }
            canSave = true
        } catch {
            canSave = false
            alert = AppAlert(
                title: "Couldn't Load Accounts",
                message: "\(error.localizedDescription)\n\nChanges won't be saved until the accounts can be loaded, so nothing is overwritten.")
        }
    }

    private func save() {
        guard canSave else {
            alert = AppAlert(title: "Not Saved", message: "Your existing accounts couldn't be read from the keychain, so changes aren't saved to avoid overwriting them. Restart the app and allow keychain access.")
            return
        }
        do {
            try store.write(try vault.encoded())
        } catch {
            alert = AppAlert(title: "Couldn't Save Accounts", message: error.localizedDescription)
        }
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ new: [OTPAccount]) -> Int {
        let n = vault.add(new)
        if n > 0 { save() }
        return n
    }

    func update(_ account: OTPAccount) {
        vault.update(account)
        save()
    }

    func delete(_ account: OTPAccount) {
        vault.remove(ids: [account.id])
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        vault.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Clipboard / feedback

    func copyCode(_ account: OTPAccount) {
        let seconds = UserDefaults.standard.integer(forKey: SettingsKey.clearClipboardSeconds)
        Clipboard.copy(account.code(), clearAfter: seconds)
    }

    func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: - Locking

    func lock() {
        guard requireUnlock else { return }
        isLocked = true
        addRequest = nil
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No way to authenticate on this Mac; don't lock the user out.
            isLocked = false
            return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your verification codes") {
                isLocked = false
            }
        } catch {
            // Cancelled or failed — stay locked.
        }
    }

    // MARK: - Importing

    /// Handles otpauth:// URLs opened from other apps, dropped text, pasted text.
    func handleIncoming(text: String) {
        guard !isLocked else { return }
        addRequest = AddRequest(mode: .link, text: text)
    }

    func addFromClipboard() {
        guard !isLocked else { return }
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty,
           pb.string(forType: .string) == nil {
            Task { await presentScanOutcome(await QRImport.fromImages(images.compactMap { QRScanner.cgImage(from: $0) })) }
        } else if let s = pb.string(forType: .string) {
            addRequest = AddRequest(mode: .link, text: s)
        } else {
            addRequest = AddRequest(mode: .link, message: "The clipboard has no otpauth:// link or QR code image.")
        }
    }

    /// Imports image files (QR codes) and/or text files (otpauth:// links, one per line).
    func importFiles(_ urls: [URL]) async {
        guard !isLocked else { return }
        var found: [OTPAccount] = []
        var errors: [String] = []
        var imageURLs: [URL] = []
        for url in urls {
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                imageURLs.append(url)
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                found += try OTPAuthURI.parseAny(text)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !imageURLs.isEmpty {
            let outcome = await QRImport.fromFiles(imageURLs)
            found += outcome.accounts
            if let e = outcome.error { errors.append(e) }
        }
        addRequest = AddRequest(mode: .scan, accounts: found, message: found.isEmpty ? errors.first : nil)
    }

    func scanScreen() async {
        guard !isLocked, !isScanningScreen else { return }
        isScanningScreen = true
        defer { isScanningScreen = false }
        await presentScanOutcome(await QRImport.fromScreen())
    }

    private func presentScanOutcome(_ outcome: QRImport.Outcome) async {
        addRequest = AddRequest(mode: .scan, accounts: outcome.accounts, message: outcome.error)
    }

    /// Imports from text backups (one otpauth:// URI per line) and/or QR images.
    func importFromFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import Accounts"
        panel.message = "Choose a text file with otpauth:// links, or images of QR codes."
        panel.allowedContentTypes = [.plainText, .text, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }

    // MARK: - Export

    func exportAccounts() {
        guard !isLocked, !accounts.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Accounts"
        panel.message = "The backup contains your secret keys in plain text. Keep it somewhere safe."
        panel.nameFieldStringValue = "Authenticator Backup.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (vault.exportURIs() + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            showBanner("Exported \(accounts.count) account\(accounts.count == 1 ? "" : "s")")
        } catch {
            alert = AppAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }
}
