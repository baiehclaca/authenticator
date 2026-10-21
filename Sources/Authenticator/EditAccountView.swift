import SwiftUI
import AuthenticatorCore

struct EditAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var account: OTPAccount
    @State private var revealSecret = false

    init(account: OTPAccount) {
        _account = State(initialValue: account)
    }

    private var isValid: Bool {
        !account.issuer.trimmingCharacters(in: .whitespaces).isEmpty
            || !account.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Issuer", text: $account.issuer)
                    TextField("Account", text: $account.name)
                }
                Section("Details") {
                    LabeledContent("Algorithm", value: account.algorithm.displayName)
                    LabeledContent("Digits", value: "\(account.digits)")
                    LabeledContent("Period", value: "\(account.period) seconds")
                    LabeledContent("Secret Key") {
                        HStack {
                            Text(revealSecret ? groupedSecret : String(repeating: "•", count: 16))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Button(revealSecret ? "Hide" : "Show") { revealSecret.toggle() }
                                .buttonStyle(.link)
                        }
                    }
                    LabeledContent("Added", value: account.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    account.issuer = account.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
                    account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.update(account)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
    }

    private var groupedSecret: String {
        let s = Array(account.base32Secret)
        return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min($0 + 4, s.count)]) }.joined(separator: " ")
    }
}

/// Shows an account's otpauth:// QR code so it can be moved to another device.
struct AccountQRView: View {
    let account: OTPAccount
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 16) {
            Text(account.displayTitle).font(.title2.weight(.semibold))
            if !account.displaySubtitle.isEmpty {
                Text(account.displaySubtitle).foregroundStyle(.secondary)
            }
            ZStack {
                if let image = QRGenerator.image(for: OTPAuthURI.build(account)) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .blur(radius: revealed ? 0 : 14)
                }
                if !revealed {
                    Button {
                        revealed = true
                    } label: {
                        Label("Show QR Code", systemImage: "eye")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(width: 240, height: 240)
            Label("Anyone who scans this code can generate your verification codes.", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}
