import XCTest
@testable import AuthenticatorCore

final class VaultTests: XCTestCase {
    func make(_ n: String, _ s: UInt8) -> OTPAccount { OTPAccount(issuer: n, name: "x", secret: [s]) }

    func testAddSkipsDuplicates() {
        var v = AccountVault()
        XCTAssertEqual(v.add([make("A", 1), make("B", 2)]), 2)
        XCTAssertEqual(v.add([make("A", 1), make("C", 3)]), 1)
        XCTAssertEqual(v.accounts.map(\.issuer), ["A", "B", "C"])
    }

    func testMove() {
        var v = AccountVault(accounts: ["A", "B", "C", "D"].enumerated().map { make($1, UInt8($0)) })
        v.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(v.accounts.map(\.issuer), ["B", "C", "A", "D"])
        v.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(v.accounts.map(\.issuer), ["D", "B", "C", "A"])
        v.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        XCTAssertEqual(v.accounts.map(\.issuer), ["B", "A", "D", "C"])
    }

    func testUpdateRemove() {
        var v = AccountVault(accounts: [make("A", 1), make("B", 2)])
        var a = v.accounts[0]; a.issuer = "Z"
        v.update(a)
        XCTAssertEqual(v.accounts[0].issuer, "Z")
        v.remove(ids: [a.id])
        XCTAssertEqual(v.accounts.map(\.issuer), ["B"])
    }

    func testCodableRoundTrip() throws {
        let v = AccountVault(accounts: [OTPAccount(issuer: "GitHub", name: "me", secret: [1, 2, 3], algorithm: .sha512, digits: 8, period: 60,
                                                   createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
        let data = try v.encoded()
        XCTAssertEqual(try AccountVault.decode(data), v)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"version\":1"), s)
        XCTAssertTrue(s.contains("\"algorithm\":\"SHA512\""), s)
    }

    func testExportURIs() throws {
        let v = AccountVault(accounts: [make("A", 1), make("B", 2)])
        let lines = v.exportURIs().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try OTPAuthURI.parseAny(v.exportURIs()).map(\.issuer), ["A", "B"])
    }
}
