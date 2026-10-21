import SwiftUI

struct LockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var attempted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Authenticator is Locked")
                .font(.title2.weight(.semibold))
            Text("Unlock with Touch ID or your password to see your codes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Prompt once automatically when the window appears.
            guard !attempted else { return }
            attempted = true
            await model.unlock()
        }
    }
}
