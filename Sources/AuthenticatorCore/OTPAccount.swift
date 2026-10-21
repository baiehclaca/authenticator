import Foundation

/// One stored authenticator account (TOTP).
public struct OTPAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var issuer: String
    public var name: String
    /// Raw (decoded) secret bytes.
    public var secret: [UInt8]
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var createdAt: Date

    public static let allowedDigits = [6, 8]
    public static let allowedPeriods = [30, 60]

    public init(
        id: UUID = UUID(),
        issuer: String,
        name: String,
        secret: [UInt8],
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.issuer = issuer
        self.name = name
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.createdAt = createdAt
    }

    /// Builds an account from user-entered fields, validating them.
    public init(manualIssuer issuer: String, name: String, base32Secret: String, algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30) throws {
        let issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issuer.isEmpty || !name.isEmpty else { throw OTPError.missingLabel }
        guard let secret = Base32.decode(base32Secret) else { throw OTPError.invalidSecret }
        guard (6...8).contains(digits) else { throw OTPError.invalidDigits }
        guard (1...300).contains(period) else { throw OTPError.invalidPeriod }
        self.init(issuer: issuer, name: name, secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    public var base32Secret: String { Base32.encode(secret) }

    /// Title shown in the list: the issuer if present, otherwise the account name.
    public var displayTitle: String { issuer.isEmpty ? name : issuer }
    /// Subtitle: account name when an issuer is shown.
    public var displaySubtitle: String { issuer.isEmpty ? "" : name }

    public func code(at date: Date = Date()) -> String {
        OTP.totp(secret: secret, date: date, period: period, digits: digits, algorithm: algorithm)
    }

    public func secondsRemaining(at date: Date = Date()) -> Double {
        OTP.secondsRemaining(at: date, period: period)
    }

    /// Case- and diacritic-insensitive search over issuer and name.
    public func matches(search query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return issuer.range(of: q, options: opts) != nil || name.range(of: q, options: opts) != nil
    }

    /// True when issuer, name and secret match (used to skip duplicate imports).
    public func isDuplicate(of other: OTPAccount) -> Bool {
        secret == other.secret && issuer == other.issuer && name == other.name
    }
}

public enum OTPError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnOTPAuthURI
    case unsupportedType(String)
    case missingSecret
    case invalidSecret
    case invalidAlgorithm(String)
    case invalidDigits
    case invalidPeriod
    case missingLabel
    case invalidMigrationPayload
    case noQRCodeFound

    public var description: String {
        switch self {
        case .notAnOTPAuthURI: "This isn't an otpauth:// link."
        case .unsupportedType(let t): "Only time-based (TOTP) codes are supported, not “\(t)”."
        case .missingSecret: "The link has no secret."
        case .invalidSecret: "The secret isn't valid Base32."
        case .invalidAlgorithm(let a): "Unsupported algorithm “\(a)”."
        case .invalidDigits: "Digits must be 6 or 8."
        case .invalidPeriod: "The period is invalid."
        case .missingLabel: "Enter an issuer or an account name."
        case .invalidMigrationPayload: "The Google Authenticator export couldn't be read."
        case .noQRCodeFound: "No authenticator QR code was found."
        }
    }
}

public func filterAccounts(_ accounts: [OTPAccount], search: String) -> [OTPAccount] {
    accounts.filter { $0.matches(search: search) }
}

extension OTPError: LocalizedError {
    public var errorDescription: String? { description }
}
