import SwiftUI
import AuthenticatorCore

struct AccountRow: View {
    let account: OTPAccount
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .center, spacing: 12) {
                IssuerBadge(title: account.displayTitle)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        if !account.displaySubtitle.isEmpty {
                            Text(account.displaySubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    LiveCode(account: account, size: 30)
                }
                Spacer(minLength: 8)
                if copied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    LiveCountdown(account: account, diameter: 30)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy the code")
        .accessibilityLabel("\(account.displayTitle) \(account.displaySubtitle)")
        .accessibilityHint("Copies the current code")
        .animation(.easeInOut(duration: 0.15), value: copied)
    }

    private func copy() {
        model.copyCode(account)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// The current code, regenerated as time passes, in large grouped monospaced digits.
struct LiveCode: View {
    let account: OTPAccount
    var size: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let code = account.code(at: context.date)
            let expiring = account.secondsRemaining(at: context.date) <= 5
            Text(OTP.formatted(code))
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(expiring ? Color.red : Color.accentColor)
                .contentTransition(.numericText())
                .animation(.default, value: code)
                .accessibilityLabel(code.map { String($0) }.joined(separator: " "))
        }
    }
}

/// Circular countdown for the current period.
struct LiveCountdown: View {
    let account: OTPAccount
    var diameter: CGFloat = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
            CountdownRing(remaining: account.secondsRemaining(at: context.date), period: account.period, diameter: diameter)
        }
    }
}

struct CountdownRing: View {
    let remaining: Double
    let period: Int
    var diameter: CGFloat = 30

    var body: some View {
        let fraction = max(0, min(1, remaining / Double(max(period, 1))))
        let color: Color = remaining <= 5 ? .red : .accentColor
        let lineWidth = max(2.5, diameter / 10)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(remaining.rounded(.up)))")
                .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("\(Int(remaining.rounded(.up))) seconds remaining")
    }
}

/// A colored circle with the issuer's initial.
struct IssuerBadge: View {
    let title: String
    var diameter: CGFloat = 36

    private static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .mint, .cyan, .brown]

    private var color: Color {
        // Stable (non-randomized) hash so a given issuer keeps its color across launches.
        var h: UInt32 = 5381
        for b in title.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    var body: some View {
        Text(title.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: diameter * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}
