import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AuthenticatorCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var editing: OTPAccount?
    @State private var showingQR: OTPAccount?
    @State private var pendingDelete: OTPAccount?
    @State private var dropTargeted = false
    @AppStorage(SettingsKey.requireUnlock) private var requireUnlock = false

    private var filtered: [OTPAccount] { filterAccounts(model.accounts, search: search) }

    var body: some View {
        Group {
            if model.isLocked {
                LockView()
            } else {
                NavigationStack {
                    accountList
                        .navigationTitle("Authenticator")
                        .searchable(text: $search, placement: .toolbar, prompt: "Search")
                        .toolbar { toolbar }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .sheet(item: $model.addRequest) { request in
            AddAccountView(request: request)
                .environmentObject(model)
        }
        .sheet(item: $editing) { account in
            EditAccountView(account: account)
                .environmentObject(model)
        }
        .sheet(item: $showingQR) { account in
            AccountQRView(account: account)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayTitle ?? "account")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let a = pendingDelete { model.delete(a) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You won't be able to generate codes for this account anymore. Make sure you've disabled two-factor authentication or have another way to sign in.")
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .overlay(alignment: .bottom) { bannerView }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }

    // MARK: - List

    @ViewBuilder
    private var accountList: some View {
        if model.accounts.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                ForEach(filtered) { account in
                    AccountRow(account: account)
                        .contextMenu { contextMenu(for: account) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = account } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                // Reordering only makes sense on the unfiltered list.
                .onMove(perform: search.isEmpty ? move : nil)
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .onDrop(of: DropImport.types, isTargeted: $dropTargeted) { providers in
                DropImport.handle(providers, model: model)
            }
            .overlay { if dropTargeted { dropHighlight } }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        model.move(fromOffsets: source, toOffset: destination)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Accounts", systemImage: "lock.shield")
        } description: {
            Text("Add an account by scanning its QR code, pasting an otpauth:// link, or entering the setup key. You can also drop a QR code image here.")
        } actions: {
            Button("Add Account…") { model.addRequest = AddRequest(mode: .scan) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: DropImport.types, isTargeted: $dropTargeted) { providers in
            DropImport.handle(providers, model: model)
        }
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(6)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func contextMenu(for account: OTPAccount) -> some View {
        Button { model.copyCode(account) } label: { Label("Copy Code", systemImage: "doc.on.doc") }
        Divider()
        Button { editing = account } label: { Label("Edit…", systemImage: "pencil") }
        Button { showingQR = account } label: { Label("Show QR Code…", systemImage: "qrcode") }
        Button {
            Clipboard.copy(OTPAuthURI.build(account), clearAfter: UserDefaults.standard.integer(forKey: SettingsKey.clearClipboardSeconds))
            model.showBanner("Setup link copied")
        } label: { Label("Copy Setup Link", systemImage: "link") }
        Divider()
        Button(role: .destructive) { pendingDelete = account } label: { Label("Delete…", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.addRequest = AddRequest(mode: .scan) } label: { Label("Scan QR Code…", systemImage: "qrcode.viewfinder") }
                Button { Task { await model.scanScreen() } } label: { Label("Scan Screen", systemImage: "rectangle.dashed.badge.record") }
                Button { model.addRequest = AddRequest(mode: .link) } label: { Label("Enter Setup Link…", systemImage: "link") }
                Button { model.addRequest = AddRequest(mode: .manual) } label: { Label("Enter Setup Key…", systemImage: "keyboard") }
                Divider()
                Button { model.addFromClipboard() } label: { Label("Add from Clipboard", systemImage: "doc.on.clipboard") }
                Button { model.importFromFiles() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            } label: {
                Label("Add Account", systemImage: "plus")
            } primaryAction: {
                model.addRequest = AddRequest(mode: .scan)
            }
            .help("Add Account")
        }
        if requireUnlock {
            ToolbarItem(placement: .automatic) {
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
                    .help("Lock Authenticator")
            }
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let text = model.banner ?? (model.isScanningScreen ? "Scanning screen…" : nil) {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Handles drag-and-drop of image files, raw images and otpauth:// text onto the window.
enum DropImport {
    static let types: [UTType] = [.fileURL, .image, .url, .plainText]

    @MainActor
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        guard !model.isLocked else { return false }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL {
                            await model.importFiles([url])
                        } else {
                            model.handleIncoming(text: url.absoluteString)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let cg = QRScanner.cgImage(from: image) else { return }
                    Task { @MainActor in
                        let outcome = await QRImport.fromImages([cg])
                        model.addRequest = AddRequest(mode: .scan, accounts: outcome.accounts, message: outcome.error)
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in model.handleIncoming(text: text) }
                }
            }
        }
        return handled
    }
}
