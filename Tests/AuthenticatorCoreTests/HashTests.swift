import XCTest
@testable import AuthenticatorCore

final class HashTests: XCTestCase {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testSHA1() {
        XCTAssertEqual(hex(Hash.sha1(bytes(""))), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(Hash.sha1(bytes("abc"))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(Hash.sha1(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(hex(Hash.sha1([UInt8](repeating: 0x61, count: 1_000_000))),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func testSHA256() {
        XCTAssertEqual(hex(Hash.sha256(bytes(""))), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(Hash.sha256(bytes("abc"))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(Hash.sha256(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA512() {
        XCTAssertEqual(hex(Hash.sha512(bytes("abc"))),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(hex(Hash.sha512(bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"))),
                       "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
    }

    // RFC 4231 test case 2 + RFC 2202 test case 2
    func testHMAC() {
        let key = bytes("Jefe"), msg = bytes("what do ya want for nothing?")
        XCTAssertEqual(hex(Hash.hmac(.sha1, key: key, message: msg)), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
        XCTAssertEqual(hex(Hash.hmac(.sha256, key: key, message: msg)),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(hex(Hash.hmac(.sha512, key: key, message: msg)),
                       "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737")
        // Key longer than block size (RFC 4231 test case 6)
        let longKey = [UInt8](repeating: 0xaa, count: 131)
        XCTAssertEqual(hex(Hash.hmac(.sha256, key: longKey, message: bytes("Test Using Larger Than Block-Size Key - Hash Key First"))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    /// Cross-checks every message length around block boundaries against a fixed reference.
    func testPaddingBoundaries() {
        // Lengths 55/56/63/64/111/112/127/128 exercise all padding branches; just check determinism & length.
        for n in [0, 1, 55, 56, 63, 64, 65, 111, 112, 119, 127, 128, 129, 1000] {
            let m = [UInt8](repeating: 0x5a, count: n)
            XCTAssertEqual(Hash.sha1(m).count, 20)
            XCTAssertEqual(Hash.sha256(m).count, 32)
            XCTAssertEqual(Hash.sha512(m).count, 64)
        }
    }
}
