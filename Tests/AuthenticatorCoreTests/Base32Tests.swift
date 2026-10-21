import XCTest
@testable import AuthenticatorCore

final class Base32Tests: XCTestCase {
    // RFC 4648 §10
    let vectors: [(String, String)] = [
        ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="), ("foob", "MZXW6YQ="),
        ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======"),
    ]

    func testEncode() {
        for (plain, enc) in vectors {
            XCTAssertEqual(Base32.encode(Array(plain.utf8), padding: true), enc)
            XCTAssertEqual(Base32.encode(Array(plain.utf8)), enc.replacingOccurrences(of: "=", with: ""))
        }
    }

    func testDecode() {
        for (plain, enc) in vectors {
            XCTAssertEqual(Base32.decode(enc), Array(plain.utf8))
            XCTAssertEqual(Base32.decode(enc.lowercased().replacingOccurrences(of: "=", with: "")), Array(plain.utf8))
        }
        XCTAssertEqual(Base32.decode("JBSW Y3DP-EHPK 3PXP"), Base32.decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(Base32.decode("JBSWY3DPEHPK3PXP"), [0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef])
    }

    func testInvalid() {
        XCTAssertNil(Base32.decode(""))
        XCTAssertNil(Base32.decode("===="))
        XCTAssertNil(Base32.decode("ABC1"))   // '1' not in alphabet
        XCTAssertNil(Base32.decode("AB=CD"))  // data after padding
        XCTAssertNil(Base32.decode("ÄBCD"))
    }

    func testRoundTrip() {
        for n in 0..<64 {
            let bytes = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            if n == 0 { continue }
            XCTAssertEqual(Base32.decode(Base32.encode(bytes)), bytes)
        }
    }
}
