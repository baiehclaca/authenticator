import Foundation

/// The ordered collection of accounts plus its (versioned) serialization.
/// Pure value type so the app's persistence/mutation rules are unit-testable.
public struct AccountVault: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var accounts: [OTPAccount]

    public init(accounts: [OTPAccount] = []) {
        self.version = Self.currentVersion
        self.accounts = accounts
    }

    /// Adds accounts, skipping exact duplicates. Returns how many were added.
    @discardableResult
    public mutating func add(_ new: [OTPAccount]) -> Int {
        var added = 0
        for a in new where !accounts.contains(where: { $0.isDuplicate(of: a) }) {
            accounts.append(a)
            added += 1
        }
        return added
    }

    public mutating func update(_ account: OTPAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account }
    }

    public mutating func remove(ids: Set<UUID>) {
        accounts.removeAll { ids.contains($0.id) }
    }

    /// Moves within the full list, as with SwiftUI's `onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { accounts[$0] }
        var remaining: [OTPAccount] = []
        var insertAt = destination
        for (i, a) in accounts.enumerated() {
            if source.contains(i) {
                if i < destination { insertAt -= 1 }
            } else {
                remaining.append(a)
            }
        }
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        accounts = remaining
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> AccountVault {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(AccountVault.self, from: data)
    }

    /// One `otpauth://` URI per line — a plain-text backup format any authenticator can import.
    public func exportURIs() -> String {
        accounts.map(OTPAuthURI.build).joined(separator: "\n")
    }
}
