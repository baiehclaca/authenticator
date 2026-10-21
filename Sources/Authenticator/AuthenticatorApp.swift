import SwiftUI
import AppKit
import AuthenticatorCore

@main
struct AuthenticatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Authenticator", id: "main") {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in model.handleIncoming(text: url.absoluteString) }
        }
        .defaultSize(width: 440, height: 600)
        .commands { AppCommands(model: model) }

        MenuBarExtra("Authenticator", systemImage: "lock.shield", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable via `swift run` (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar extra if it's enabled.
        !UserDefaults.standard.bool(forKey: SettingsKey.showMenuBarExtra)
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Account…") { present(AddRequest(mode: .scan)) }
                .keyboardShortcut("n")
                .disabled(model.isLocked)
            Button("Scan Screen for QR Code") {
                openWindow(id: "main")
                Task { await model.scanScreen() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.isLocked)
            Button("Add from Clipboard") {
                openWindow(id: "main")
                model.addFromClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(model.isLocked)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import…") {
                openWindow(id: "main")
                model.importFromFiles()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.isLocked)
            Button("Export Accounts…") { model.exportAccounts() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.isLocked || model.accounts.isEmpty)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Lock Authenticator") { model.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!model.requireUnlock || model.isLocked)
        }
    }

    private func present(_ request: AddRequest) {
        openWindow(id: "main")
        model.addRequest = request
    }
}
