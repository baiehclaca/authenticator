import Foundation

/// Parsing and building of `otpauth://totp/...` key URIs
/// (https://github.com/google/google-authenticator/wiki/Key-Uri-Format).
public enum OTPAuthURI {
    /// Parses a single `otpauth://totp/...` URI.
    public static func parse(_ input: String) throws -> OTPAccount {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "otpauth://"
        guard s.count > prefix.count, s.lowercased().hasPrefix(prefix) else { throw OTPError.notAnOTPAuthURI }
        let rest = s.dropFirst(prefix.count)

        // type / label ? query (# fragment ignored)
        let withoutFragment = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pathAndQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathAndQuery[0]
        let query = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""

        let typeAndLabel = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let type = String(typeAndLabel[0]).lowercased()
        guard type == "totp" else {
            if type.isEmpty { throw OTPError.notAnOTPAuthURI }
            throw OTPError.unsupportedType(type)
        }
        let rawLabel = typeAndLabel.count > 1 ? String(typeAndLabel[1]) : ""

        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecode(String(kv[0]), plusAsSpace: true).lowercased()
            let value = kv.count > 1 ? percentDecode(String(kv[1]), plusAsSpace: true) : ""
            if params[key] == nil { params[key] = value } // first wins
        }

        guard let secretString = params["secret"], !secretString.isEmpty else { throw OTPError.missingSecret }
        guard let secret = Base32.decode(secretString) else { throw OTPError.invalidSecret }

        // Label is "Issuer:Account" or "Account" (colon may be encoded as %3A, handled by decoding).
        // Prefer a literal ':' as the separator (so an encoded %3A inside the issuer survives);
        // otherwise fall back to the first colon after decoding.
        var labelIssuer = ""
        var accountName: String
        if let colon = rawLabel.firstIndex(of: ":") {
            labelIssuer = percentDecode(String(rawLabel[..<colon]), plusAsSpace: false).trimmingCharacters(in: .whitespaces)
            accountName = percentDecode(String(rawLabel[rawLabel.index(after: colon)...]), plusAsSpace: false)
        } else {
            let label = percentDecode(rawLabel, plusAsSpace: false)
            accountName = label
            if let colon = label.firstIndex(of: ":") {
                labelIssuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
                accountName = String(label[label.index(after: colon)...])
            }
        }
        accountName = accountName.trimmingCharacters(in: .whitespaces)
        let paramIssuer = params["issuer"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let issuer = paramIssuer.isEmpty ? labelIssuer : paramIssuer

        var algorithm = OTPAlgorithm.sha1
        if let a = params["algorithm"], !a.isEmpty {
            guard let parsed = OTPAlgorithm(lenient: a) else { throw OTPError.invalidAlgorithm(a) }
            algorithm = parsed
        }
        var digits = 6
        if let d = params["digits"], !d.isEmpty {
            guard let v = Int(d), (6...8).contains(v) else { throw OTPError.invalidDigits }
            digits = v
        }
        var period = 30
        if let p = params["period"], !p.isEmpty {
            guard let v = Int(p), (1...300).contains(v) else { throw OTPError.invalidPeriod }
            period = v
        }
        return OTPAccount(issuer: issuer, name: accountName, secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    /// Parses any supported text: an `otpauth://` URI, an `otpauth-migration://` export
    /// (Google Authenticator "Transfer accounts"), or several of them separated by whitespace.
    public static func parseAny(_ input: String) throws -> [OTPAccount] {
        let tokens = input.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }).map(String.init)
        // A single otpauth URI may contain unencoded spaces in its label; try the whole string first.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://"), !trimmed.contains("\n") {
            if let a = try? parse(trimmed) { return [a] }
        }
        var result: [OTPAccount] = []
        var firstError: Error?
        for token in tokens {
            do {
                if token.lowercased().hasPrefix("otpauth-migration://") {
                    result += try GoogleAuthenticatorMigration.parse(token)
                } else {
                    result.append(try parse(token))
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if result.isEmpty { throw firstError ?? OTPError.notAnOTPAuthURI }
        return result
    }

    /// Builds a canonical `otpauth://totp/...` URI for an account (used for export / QR display).
    public static func build(_ account: OTPAccount) -> String {
        let label: String
        if account.issuer.isEmpty {
            label = percentEncode(account.name)
        } else {
            label = percentEncode(account.issuer) + ":" + percentEncode(account.name)
        }
        var query = ["secret=" + account.base32Secret]
        if !account.issuer.isEmpty { query.append("issuer=" + percentEncode(account.issuer)) }
        query.append("algorithm=" + account.algorithm.rawValue)
        query.append("digits=\(account.digits)")
        query.append("period=\(account.period)")
        return "otpauth://totp/" + label + "?" + query.joined(separator: "&")
    }

    // MARK: - Percent coding

    static func percentDecode(_ s: String, plusAsSpace: Bool) -> String {
        let src = plusAsSpace ? s.replacingOccurrences(of: "+", with: " ") : s
        // Manual decoder: tolerant of stray '%' (kept literally) unlike removingPercentEncoding.
        var bytes: [UInt8] = []
        var it = Array(src.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "%"), it.count >= 2,
               let h = hexValue(it[it.startIndex]), let l = hexValue(it[it.startIndex + 1]) {
                bytes.append(h << 4 | l)
                it = it.dropFirst(2)
            } else {
                bytes.append(c)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    static func percentEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "@"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                let hex = Array("0123456789ABCDEF")
                out += "%" + String(hex[Int(b >> 4)]) + String(hex[Int(b & 0xF)])
            }
        }
        return out
    }
}
