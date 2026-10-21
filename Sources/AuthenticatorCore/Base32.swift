/// RFC 4648 Base32 (the alphabet used by otpauth secrets).
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    private static let decodeTable: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() {
            t[Int(c)] = Int8(i)
            // lower-case variants
            if c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") { t[Int(c + 32)] = Int8(i) }
        }
        return t
    }()

    /// Decodes Base32, case-insensitively, ignoring spaces, hyphens and `=` padding.
    /// Returns `nil` on any invalid character or an empty result.
    public static func decode(_ string: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(string.utf8.count * 5 / 8)
        var buffer: UInt32 = 0
        var bits = 0
        var sawPadding = false
        for c in string.utf8 {
            switch c {
            case UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: "="):
                sawPadding = true
                continue
            default:
                break
            }
            if sawPadding { return nil } // data after padding
            let v = decodeTable[Int(c)]
            guard v >= 0 else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return out.isEmpty ? nil : out
    }

    /// Encodes bytes as upper-case Base32. Padding is omitted by default (as in otpauth URIs).
    public static func encode(_ bytes: [UInt8], padding: Bool = false) -> String {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        if padding {
            while out.count % 8 != 0 { out.append(UInt8(ascii: "=")) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Whether the string is a usable Base32 secret.
    public static func isValid(_ string: String) -> Bool { decode(string) != nil }
}
