import Foundation

/// Decoder for Google Authenticator "Transfer accounts" QR codes:
/// `otpauth-migration://offline?data=<base64 protobuf MigrationPayload>`.
///
/// ```
/// message MigrationPayload { repeated OtpParameters otp_parameters = 1; int32 version = 2; ... }
/// message OtpParameters {
///   bytes secret = 1; string name = 2; string issuer = 3;
///   Algorithm algorithm = 4;  // 0 unspecified, 1 SHA1, 2 SHA256, 3 SHA512, 4 MD5
///   DigitCount digits = 5;    // 0 unspecified, 1 six, 2 eight
///   OtpType type = 6;         // 0 unspecified, 1 HOTP, 2 TOTP
///   int64 counter = 7;
/// }
/// ```
/// HOTP and MD5 entries are skipped (unsupported).
public enum GoogleAuthenticatorMigration {
    public static func parse(_ uri: String) throws -> [OTPAccount] {
        let s = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("otpauth-migration://") else { throw OTPError.notAnOTPAuthURI }
        guard let q = s.firstIndex(of: "?") else { throw OTPError.invalidMigrationPayload }
        var dataParam: String?
        for pair in s[s.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv[0] == "data", kv.count > 1 {
                // '+' here is a literal base64 character when percent-encoded properly, but some
                // tools leave it raw; never treat it as a space.
                dataParam = OTPAuthURI.percentDecode(String(kv[1]), plusAsSpace: false)
            }
        }
        guard var b64 = dataParam, !b64.isEmpty else { throw OTPError.invalidMigrationPayload }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw OTPError.invalidMigrationPayload }
        return try decodePayload([UInt8](data))
    }

    static func decodePayload(_ bytes: [UInt8]) throws -> [OTPAccount] {
        var reader = ProtoReader(bytes: bytes[...])
        var accounts: [OTPAccount] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            if field == 1, wire == 2 {
                if let a = try decodeParameters(try reader.readLengthDelimited()) { accounts.append(a) }
            } else {
                try reader.skip(wire: wire)
            }
        }
        return accounts
    }

    private static func decodeParameters(_ bytes: ArraySlice<UInt8>) throws -> OTPAccount? {
        var r = ProtoReader(bytes: bytes)
        var secret: [UInt8] = []
        var name = "", issuer = ""
        var algorithm: UInt64 = 0, digits: UInt64 = 0, type: UInt64 = 0
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, 2): secret = Array(try r.readLengthDelimited())
            case (2, 2): name = String(decoding: try r.readLengthDelimited(), as: UTF8.self)
            case (3, 2): issuer = String(decoding: try r.readLengthDelimited(), as: UTF8.self)
            case (4, 0): algorithm = try r.readVarint()
            case (5, 0): digits = try r.readVarint()
            case (6, 0): type = try r.readVarint()
            default: try r.skip(wire: wire)
            }
        }
        guard !secret.isEmpty else { return nil }
        if type == 1 { return nil } // HOTP unsupported
        let algo: OTPAlgorithm
        switch algorithm {
        case 0, 1: algo = .sha1
        case 2: algo = .sha256
        case 3: algo = .sha512
        default: return nil // MD5 / unknown
        }
        // Name is often "Issuer:account" — strip a duplicated issuer prefix.
        var account = name
        if let colon = name.firstIndex(of: ":") {
            let prefix = String(name[..<colon]).trimmingCharacters(in: .whitespaces)
            if issuer.isEmpty { issuer = prefix }
            if prefix == issuer { account = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        return OTPAccount(issuer: issuer, name: account, secret: secret, algorithm: algo, digits: digits == 2 ? 8 : 6, period: 30)
    }
}

/// Minimal protobuf wire-format reader.
struct ProtoReader {
    var bytes: ArraySlice<UInt8>
    var isAtEnd: Bool { bytes.isEmpty }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let b = bytes.popFirst(), shift < 64 else { throw OTPError.invalidMigrationPayload }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readTag() throws -> (field: UInt64, wire: UInt64) {
        let tag = try readVarint()
        return (tag >> 3, tag & 7)
    }

    mutating func readLengthDelimited() throws -> ArraySlice<UInt8> {
        let len = try readVarint()
        guard len <= UInt64(bytes.count) else { throw OTPError.invalidMigrationPayload }
        let start = bytes.startIndex
        let out = bytes[start..<(start + Int(len))]
        bytes = bytes[(start + Int(len))...]
        return out
    }

    mutating func skip(wire: UInt64) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: try drop(8)
        case 2: _ = try readLengthDelimited()
        case 5: try drop(4)
        default: throw OTPError.invalidMigrationPayload
        }
    }

    private mutating func drop(_ n: Int) throws {
        guard bytes.count >= n else { throw OTPError.invalidMigrationPayload }
        bytes = bytes.dropFirst(n)
    }
}
