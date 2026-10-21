import Foundation

public enum OTPAlgorithm: String, Codable, CaseIterable, Sendable, Identifiable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha512: "SHA-512"
        }
    }

    /// Lenient parsing: "sha1", "SHA-1", "HmacSHA1" … all work.
    public init?(lenient string: String) {
        let s = string.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "HMAC", with: "")
        guard let v = OTPAlgorithm(rawValue: s) else { return nil }
        self = v
    }
}

public enum OTP {
    /// HOTP (RFC 4226) with dynamic truncation; supports any HMAC algorithm.
    public static func hotp(secret: [UInt8], counter: UInt64, digits: Int = 6, algorithm: OTPAlgorithm = .sha1) -> String {
        precondition((1...10).contains(digits), "digits out of range")
        var msg = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { msg[7 - i] = UInt8(truncatingIfNeeded: counter >> (UInt64(i) * 8)) }
        let mac = Hash.hmac(algorithm, key: secret, message: msg)
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulo: UInt64 = 1
        for _ in 0..<digits { modulo *= 10 }
        let value = UInt64(binary) % modulo
        let s = String(value)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    /// The TOTP time step for `date` (RFC 6238, T0 = 0).
    public static func counter(at date: Date, period: Int) -> UInt64 {
        let t = date.timeIntervalSince1970
        guard t > 0, period > 0 else { return 0 }
        return UInt64(floor(t / Double(period)))
    }

    public static func totp(secret: [UInt8], date: Date, period: Int = 30, digits: Int = 6, algorithm: OTPAlgorithm = .sha1) -> String {
        hotp(secret: secret, counter: counter(at: date, period: period), digits: digits, algorithm: algorithm)
    }

    /// Seconds remaining (fractional) in the current period.
    public static func secondsRemaining(at date: Date, period: Int) -> Double {
        let p = Double(max(period, 1))
        let t = date.timeIntervalSince1970
        let r = p - t.truncatingRemainder(dividingBy: p)
        return r <= 0 ? p : r
    }

    /// Fraction (1 → 0) of the current period remaining; drives the countdown ring.
    public static func progressRemaining(at date: Date, period: Int) -> Double {
        secondsRemaining(at: date, period: period) / Double(max(period, 1))
    }

    /// Groups a code for display: "123456" → "123 456", "12345678" → "1234 5678".
    public static func formatted(_ code: String) -> String {
        let chars = Array(code)
        let groupSize: Int
        switch chars.count {
        case 6: groupSize = 3
        case 8: groupSize = 4
        case 7: groupSize = 4 // 1234 567
        default: return code
        }
        return String(chars[0..<groupSize]) + " " + String(chars[groupSize...])
    }
}
