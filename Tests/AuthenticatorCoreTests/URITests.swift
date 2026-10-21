import XCTest
@testable import AuthenticatorCore

final class URITests: XCTestCase {
    func testGoogleExample() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")
        XCTAssertEqual(a.issuer, "Example")
        XCTAssertEqual(a.name, "alice@google.com")
        XCTAssertEqual(a.base32Secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(a.algorithm, .sha1)
        XCTAssertEqual(a.digits, 6)
        XCTAssertEqual(a.period, 30)
    }

    func testFullParameters() throws {
        let a = try OTPAuthURI.parse("otpauth://totp/ACME%20Co:john.doe%40email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA512&digits=8&period=60")
        XCTAssertEqual(a.issuer, "ACME Co")
        XCTAssertEqual(a.name, "john.doe@email.com")
        XCTAssertEqual(a.algorithm, .sha512)
        XCTAssertEqual(a.digits, 8)
        XCTAssertEqual(a.period, 60)
    }

    func testVariants() throws {
        // issuer only in label, encoded colon, lowercase scheme/type, lowercase secret, extra spaces
        let a = try OTPAuthURI.parse("  OTPAUTH://TOTP/GitHub%3A%20teo?secret=jbswy3dpehpk3pxp&algorithm=sha256  ")
        XCTAssertEqual(a.issuer, "GitHub")
        XCTAssertEqual(a.name, "teo")
        XCTAssertEqual(a.algorithm, .sha256)
        // issuer param overrides label prefix; '+' in query = space
        let b = try OTPAuthURI.parse("otpauth://totp/old:bob?issuer=New+Name&secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(b.issuer, "New Name")
        // no issuer at all
        let c = try OTPAuthURI.parse("otpauth://totp/bob?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(c.issuer, "")
        XCTAssertEqual(c.name, "bob")
        XCTAssertEqual(c.displayTitle, "bob")
        // unencoded space in label
        let d = try OTPAuthURI.parseAny("otpauth://totp/My Bank:me?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(d.first?.issuer, "My Bank")
    }

    func testErrors() {
        XCTAssertThrowsError(try OTPAuthURI.parse("https://example.com")) { XCTAssertEqual($0 as? OTPError, .notAnOTPAuthURI) }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1")) {
            XCTAssertEqual($0 as? OTPError, .unsupportedType("hotp"))
        }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?issuer=y")) { XCTAssertEqual($0 as? OTPError, .missingSecret) }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?secret=11111")) { XCTAssertEqual($0 as? OTPError, .invalidSecret) }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=4")) { XCTAssertEqual($0 as? OTPError, .invalidDigits) }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5")) {
            XCTAssertEqual($0 as? OTPError, .invalidAlgorithm("MD5"))
        }
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=0")) { XCTAssertEqual($0 as? OTPError, .invalidPeriod) }
    }

    func testBuildRoundTrip() throws {
        let a = OTPAccount(issuer: "ACME Co: Ü", name: "john doe@x.com", secret: Array("12345678901234567890".utf8), algorithm: .sha256, digits: 8, period: 60)
        let uri = OTPAuthURI.build(a)
        XCTAssertTrue(uri.hasPrefix("otpauth://totp/ACME%20Co%3A%20%C3%9C:john%20doe@x.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer="), uri)
        let b = try OTPAuthURI.parse(uri)
        XCTAssertEqual(b.issuer, a.issuer)
        XCTAssertEqual(b.name, a.name)
        XCTAssertEqual(b.secret, a.secret)
        XCTAssertEqual(b.algorithm, a.algorithm)
        XCTAssertEqual(b.digits, 8)
        XCTAssertEqual(b.period, 60)
    }

    func testParseAnyMultiple() throws {
        let text = """
        otpauth://totp/A:a?secret=JBSWY3DPEHPK3PXP&issuer=A
        garbage
        otpauth://totp/B:b?secret=GEZDGNBVGY3TQOJQ&issuer=B
        """
        let r = try OTPAuthURI.parseAny(text)
        XCTAssertEqual(r.map(\.issuer), ["A", "B"])
        XCTAssertThrowsError(try OTPAuthURI.parseAny("nothing here"))
    }

    func testGoogleMigration() throws {
        // Build a MigrationPayload by hand: two TOTP entries (one SHA256/8 digits) + one HOTP (skipped).
        func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
            return out
        }
        func field(_ n: UInt64, _ bytes: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
        func field(_ n: UInt64, int v: UInt64) -> [UInt8] { varint(n << 3) + varint(v) }
        let p1 = field(1, Array("12345678901234567890".utf8)) + field(2, Array("ACME:alice".utf8)) + field(3, Array("ACME".utf8))
            + field(4, int: 1) + field(5, int: 1) + field(6, int: 2)
        let p2 = field(1, [1, 2, 3, 4, 5]) + field(2, Array("bob".utf8)) + field(4, int: 2) + field(5, int: 2) + field(6, int: 2)
        let p3 = field(1, [9, 9]) + field(2, Array("hotp".utf8)) + field(6, int: 1) + field(7, int: 5)
        let payload = field(1, p1) + field(1, p2) + field(1, p3) + field(2, int: 1) + field(3, int: 1) + field(4, int: 0)
        let b64 = Data(payload).base64EncodedString()
        let encoded = b64.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        let accounts = try OTPAuthURI.parseAny("otpauth-migration://offline?data=\(encoded)")
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].issuer, "ACME")
        XCTAssertEqual(accounts[0].name, "alice")
        XCTAssertEqual(accounts[0].code(at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(accounts[1].name, "bob")
        XCTAssertEqual(accounts[1].algorithm, .sha256)
        XCTAssertEqual(accounts[1].digits, 8)
        XCTAssertThrowsError(try GoogleAuthenticatorMigration.parse("otpauth-migration://offline?data=%%%"))
    }
}
