import SwiftUI
import AppKit
import AuthenticatorCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var filtered: [OTPAccount] { filterAccounts(model.accounts, search: search) }

    var body: some View {
        VStack(spacing: 0) {
            if model.isLocked {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.title).foregroundStyle(.secondary)
                    Button {
                        Task { await model.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "touchid")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            } else if model.accounts.isEmpty {
                Text("No accounts yet")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            } else {
                if model.accounts.count > 4 {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { account in
                            MenuBarRow(account: account)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(filtered.count, 1)) * 58, 420))
            }
            Divider()
            HStack {
                Button("Open Authenticator") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 320)
        // The menu bar panel stays alive after it closes; stop the codes ticking then.
        .pausesCodesWhenHidden()
    }
}

private struct MenuBarRow: View {
    let account: OTPAccount
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            model.copyCode(account)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !account.displaySubtitle.isEmpty {
                        Text(account.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if copied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    LiveCode(account: account, size: 20)
                }
                LiveCountdown(account: account, diameter: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
