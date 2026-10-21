import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AuthenticatorCore

enum AddMode: String, CaseIterable, Identifiable {
    case scan, link, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .scan: "Scan QR Code"
        case .link: "Setup Link"
        case .manual: "Setup Key"
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AddMode
    @State private var message: String?

    // Scan
    @State private var scanResults: [OTPAccount]
    @State private var isScanning = false
    @State private var dropTargeted = false
    @State private var needsScreenPermission = false
    @State private var showCamera = false

    // Link
    @State private var linkText: String
    @State private var linkResults: [OTPAccount] = []
    @State private var linkError: String?

    // Manual
    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secret = ""
    @State private var digits = 6
    @State private var period = 30
    @State private var algorithm: OTPAlgorithm = .sha1

    init(request: AddRequest) {
        _mode = State(initialValue: request.mode)
        _message = State(initialValue: request.message)
        _scanResults = State(initialValue: request.accounts)
        _linkText = State(initialValue: request.text)
        if !request.text.isEmpty {
            switch Result(catching: { try OTPAuthURI.parseAny(request.text) }) {
            case .success(let accounts): _linkResults = State(initialValue: accounts)
            case .failure(let error): _linkError = State(initialValue: error.localizedDescription)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Method", selection: $mode) {
                ForEach(AddMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)

            Group {
                switch mode {
                case .scan: scanPane
                case .link: linkPane
                case .manual: manualPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 500, height: 560)
        .onChange(of: mode) { message = nil }
    }

    // MARK: - Scan

    private var scanPane: some View {
        VStack(spacing: 14) {
            if scanResults.isEmpty {
                dropZone
            } else {
                AccountPreviewList(accounts: $scanResults)
            }
            HStack {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    .help("Scan a QR code (e.g. Google Authenticator's Transfer accounts export) with your Mac's camera")
                Button { chooseImage() } label: { Label("Choose Image…", systemImage: "photo") }
                Button { pasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                Button { Task { await scanScreen() } } label: { Label("Scan Screen", systemImage: "rectangle.dashed.badge.record") }
                    .help("Looks for a QR code anywhere on your displays (needs Screen Recording permission)")
            }
            .disabled(isScanning)
            if needsScreenPermission {
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .sheet(isPresented: $showCamera) {
            CameraScanView { payload in
                let outcome = QRImport.outcome(for: [payload])
                if outcome.accounts.isEmpty { return outcome.error ?? "That QR code isn't an authenticator code." }
                for a in outcome.accounts where !scanResults.contains(where: { $0.isDuplicate(of: a) }) {
                    scanResults.append(a)
                }
                message = nil
                return nil
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background((dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear),
                            in: RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 10) {
                if isScanning {
                    ProgressView()
                    Text("Looking for a QR code…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Drop a QR code image here")
                        .font(.title3.weight(.medium))
                    Text("…or choose an image, paste a screenshot, or scan what's on your screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose QR Code Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await scan { await QRImport.fromFiles(urls) } }
    }

    private func pasteImage() {
        let pb = NSPasteboard.general
        var images: [CGImage] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            images += urls.compactMap { QRScanner.cgImage(from: $0) }
        }
        if images.isEmpty, let nsImages = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            images += nsImages.compactMap { QRScanner.cgImage(from: $0) }
        }
        if images.isEmpty {
            // Maybe the clipboard holds a link instead.
            if let text = pb.string(forType: .string), text.lowercased().contains("otpauth") {
                mode = .link
                linkText = text
                parseLink()
            } else {
                message = "The clipboard doesn't contain an image."
            }
            return
        }
        Task { await scan { await QRImport.fromImages(images) } }
    }

    private func scanScreen() async {
        await scan { await QRImport.fromScreen() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await scan { await QRImport.fromFiles([url]) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let cg = QRScanner.cgImage(from: image) else { return }
                    Task { @MainActor in await scan { await QRImport.fromImages([cg]) } }
                }
            }
        }
        return handled
    }

    @MainActor
    private func scan(_ work: () async -> QRImport.Outcome) async {
        isScanning = true
        message = nil
        let outcome = await work()
        isScanning = false
        needsScreenPermission = outcome.needsScreenPermission
        if outcome.accounts.isEmpty {
            message = outcome.error
        } else {
            for a in outcome.accounts where !scanResults.contains(where: { $0.isDuplicate(of: a) }) {
                scanResults.append(a)
            }
        }
    }

    // MARK: - Link

    private var linkPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the otpauth:// link from the site's 2FA setup page. Google Authenticator export links (otpauth-migration://) work too.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $linkText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if linkText.isEmpty {
                    Text("otpauth://totp/Example:you@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .onChange(of: linkText) { parseLink() }

            HStack {
                Button { pasteLink() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                Spacer()
                if let linkError, !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(linkError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
            if !linkResults.isEmpty {
                AccountPreviewList(accounts: $linkResults)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func pasteLink() {
        if let s = NSPasteboard.general.string(forType: .string) {
            linkText = s
            parseLink()
        }
    }

    private func parseLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            linkResults = []
            linkError = nil
            return
        }
        do {
            linkResults = try OTPAuthURI.parseAny(text)
            linkError = nil
        } catch {
            linkResults = []
            linkError = error.localizedDescription
        }
    }

    // MARK: - Manual

    private var manualAccount: Result<OTPAccount, Error> {
        Result {
            try OTPAccount(manualIssuer: issuer, name: accountName, base32Secret: secret,
                           algorithm: algorithm, digits: digits, period: period)
        }
    }

    private var secretIsInvalid: Bool {
        !secret.trimmingCharacters(in: .whitespaces).isEmpty && !Base32.isValid(secret)
    }

    private var manualPane: some View {
        Form {
            Section {
                TextField("Issuer", text: $issuer, prompt: Text("e.g. GitHub"))
                TextField("Account", text: $accountName, prompt: Text("e.g. you@example.com"))
                TextField("Secret Key", text: $secret, prompt: Text("e.g. JBSW Y3DP EHPK 3PXP"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                if secretIsInvalid {
                    Label("The key should contain only letters A–Z and digits 2–7.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            Section("Advanced") {
                Picker("Digits", selection: $digits) {
                    Text("6").tag(6)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                Picker("Period", selection: $period) {
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                .pickerStyle(.segmented)
                Picker("Algorithm", selection: $algorithm) {
                    ForEach(OTPAlgorithm.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if case .success(let account) = manualAccount {
                Section("Preview") {
                    HStack {
                        LiveCode(account: account, size: 24)
                        Spacer()
                        LiveCountdown(account: account, diameter: 24)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var pending: [OTPAccount] {
        switch mode {
        case .scan: scanResults
        case .link: linkResults
        case .manual: (try? manualAccount.get()).map { [$0] } ?? []
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(pending.count > 1 ? "Add \(pending.count) Accounts" : "Add Account") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.isEmpty)
        }
        .padding(16)
    }

    private func commit() {
        let toAdd = pending
        guard !toAdd.isEmpty else { return }
        let added = model.add(toAdd)
        if added == 0 {
            message = toAdd.count == 1 ? "This account has already been added." : "These accounts have already been added."
            return
        }
        let skipped = toAdd.count - added
        model.showBanner(skipped > 0
            ? "Added \(added), skipped \(skipped) already added"
            : "Added \(added) account\(added == 1 ? "" : "s")")
        dismiss()
    }
}

/// Review list of accounts about to be added (issuer/name editable, removable).
struct AccountPreviewList: View {
    @Binding var accounts: [OTPAccount]

    var body: some View {
        List {
            ForEach($accounts) { $account in
                HStack(spacing: 10) {
                    IssuerBadge(title: account.displayTitle, diameter: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Issuer", text: $account.issuer)
                            .textFieldStyle(.plain)
                            .font(.headline)
                        TextField("Account", text: $account.name)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.secondary)
                        Text("\(account.digits) digits · \(account.period) s · \(account.algorithm.displayName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        accounts.removeAll { $0.id == account.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Don't add this account")
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 120)
    }
}
