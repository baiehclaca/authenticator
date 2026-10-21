import XCTest
@testable import AuthenticatorCore

final class OTPTests: XCTestCase {
    // RFC 4226 Appendix D
    func testHOTPVectors() {
        let secret = Array("12345678901234567890".utf8)
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(OTP.hotp(secret: secret, counter: UInt64(i)), e, "counter \(i)")
        }
    }

    // RFC 6238 Appendix B (8 digits)
    func testTOTPVectors() {
        let s1 = Array("12345678901234567890".utf8)
        let s256 = Array("12345678901234567890123456789012".utf8)
        let s512 = Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let cases: [(TimeInterval, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1111111109, "07081804", "68084774", "25091201"),
            (1111111111, "14050471", "67062674", "99943326"),
            (1234567890, "89005924", "91819424", "93441116"),
            (2000000000, "69279037", "90698825", "38618901"),
            (20000000000, "65353130", "77737706", "47863826"),
        ]
        for (t, e1, e256, e512) in cases {
            let d = Date(timeIntervalSince1970: t)
            XCTAssertEqual(OTP.totp(secret: s1, date: d, digits: 8, algorithm: .sha1), e1, "sha1 @\(t)")
            XCTAssertEqual(OTP.totp(secret: s256, date: d, digits: 8, algorithm: .sha256), e256, "sha256 @\(t)")
            XCTAssertEqual(OTP.totp(secret: s512, date: d, digits: 8, algorithm: .sha512), e512, "sha512 @\(t)")
        }
    }

    func testSixDigitsAndPeriod60() {
        let s1 = Array("12345678901234567890".utf8)
        // 6-digit code is the last 6 digits of the 8-digit one (same truncation, mod 10^6).
        XCTAssertEqual(OTP.totp(secret: s1, date: Date(timeIntervalSince1970: 1111111109), digits: 6), "081804")
        // period 60 at t=120 → counter 2 → RFC 4226 value for counter 2
        XCTAssertEqual(OTP.totp(secret: s1, date: Date(timeIntervalSince1970: 120), period: 60), "359152")
        XCTAssertEqual(OTP.counter(at: Date(timeIntervalSince1970: 119.9), period: 60), 1)
    }

    func testRemaining() {
        XCTAssertEqual(OTP.secondsRemaining(at: Date(timeIntervalSince1970: 0.000001 + 30), period: 30), 30, accuracy: 0.001)
        XCTAssertEqual(OTP.secondsRemaining(at: Date(timeIntervalSince1970: 1_000_000_040), period: 30), 10, accuracy: 0.0001)
        XCTAssertEqual(OTP.progressRemaining(at: Date(timeIntervalSince1970: 1_000_000_040), period: 30), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(OTP.secondsRemaining(at: Date(timeIntervalSince1970: 1_000_000_040), period: 60), 40, accuracy: 0.0001)
    }

    func testFormatting() {
        XCTAssertEqual(OTP.formatted("123456"), "123 456")
        XCTAssertEqual(OTP.formatted("12345678"), "1234 5678")
        XCTAssertEqual(OTP.formatted("1234567"), "1234 567")
        XCTAssertEqual(OTP.formatted("12345"), "12345")
    }

    func testAccountCodeUsesSettings() throws {
        let a = try OTPAccount(manualIssuer: "ACME", name: "me", base32Secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8)
        XCTAssertEqual(a.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(a.displayTitle, "ACME")
        XCTAssertEqual(a.displaySubtitle, "me")
    }

    func testManualValidation() {
        XCTAssertThrowsError(try OTPAccount(manualIssuer: "", name: " ", base32Secret: "JBSWY3DPEHPK3PXP")) {
            XCTAssertEqual($0 as? OTPError, .missingLabel)
        }
        XCTAssertThrowsError(try OTPAccount(manualIssuer: "X", name: "", base32Secret: "not base32!")) {
            XCTAssertEqual($0 as? OTPError, .invalidSecret)
        }
        XCTAssertNoThrow(try OTPAccount(manualIssuer: "X", name: "", base32Secret: "jbsw y3dp ehpk 3pxp"))
    }

    func testSearch() {
        let a = OTPAccount(issuer: "GitHub", name: "teo@example.com", secret: [1])
        let b = OTPAccount(issuer: "Société Générale", name: "client", secret: [2])
        XCTAssertEqual(filterAccounts([a, b], search: "git").map(\.id), [a.id])
        XCTAssertEqual(filterAccounts([a, b], search: "EXAMPLE").map(\.id), [a.id])
        XCTAssertEqual(filterAccounts([a, b], search: "societe").map(\.id), [b.id])
        XCTAssertEqual(filterAccounts([a, b], search: "  ").count, 2)
    }
}
