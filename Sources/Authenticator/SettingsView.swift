import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.requireUnlock) private var requireUnlock = false
    @AppStorage(SettingsKey.clearClipboardSeconds) private var clearClipboardSeconds = 30
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some View {
        Form {
            Section("Security") {
                Toggle("Require Touch ID or password to show codes", isOn: $requireUnlock)
                Text("Authenticator locks when it launches, when the screen locks, and when you choose Window › Lock Authenticator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Clear copied codes from the clipboard", selection: $clearClipboardSeconds) {
                    Text("Never").tag(0)
                    Text("After 15 seconds").tag(15)
                    Text("After 30 seconds").tag(30)
                    Text("After 1 minute").tag(60)
                    Text("After 2 minutes").tag(120)
                }
            }
            Section("Menu Bar") {
                Toggle("Show codes in the menu bar", isOn: $showMenuBarExtra)
            }
            Section("Storage") {
                LabeledContent("Accounts", value: "\(model.accounts.count)")
                Text("Secrets are stored in your login keychain (service “\(AppModel.keychainService)”). Use File › Export Accounts… to make a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isLocked)
        .overlay(alignment: .top) {
            if model.isLocked {
                Button {
                    Task { await model.unlock() }
                } label: {
                    Label("Unlock to change settings", systemImage: "lock.fill")
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: requireUnlock) {
            if !requireUnlock { model.isLocked = false }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
