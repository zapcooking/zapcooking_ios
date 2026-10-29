import Foundation
import Testing
@testable import wisp

struct Nip49Tests {

    @Test func scryptMatchesRFC7914Vector() throws {
        // RFC 7914 §12: P="password", S="NaCl", N=1024 (log_n=10), r=8, p=1, dkLen=64
        let out = try Nip49.scrypt(
            password: Array("password".utf8),
            salt: Array("NaCl".utf8),
            logN: 10, r: 8, p: 1, dkLen: 64
        )
        #expect(out.map { String(format: "%02x", $0) }.joined()
            == "27b418c674c769d12501fbb1f53bac32df6514c0f28d043872b148b348961a79057a6861cc3553246aa0ddb63bc074450b924022547a799538d603396835dd62")
    }

    @Test func decryptsNip49SpecVector() throws {
        // NIP-49 §Test Data: password "nostr", log_n=16.
        let ncryptsec = "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
        let key = try Nip49.decrypt(ncryptsec, password: "nostr")
        #expect(key.map { String(format: "%02x", $0) }.joined()
            == "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683")
    }

    @Test func wrongPasswordThrows() {
        let ncryptsec = "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
        #expect(throws: Nip49.CryptoError.wrongPassword) {
            try Nip49.decrypt(ncryptsec, password: "wrong")
        }
    }

    @Test func malformedInputThrows() {
        // Valid bech32, wrong hrp / shape.
        #expect(throws: Nip49.CryptoError.malformed) {
            try Nip49.decrypt("nsec1vl83hlkfruu86vs2smtv4m5v0nzjpst5sw52s4naxce7anmb8puqr0u60", password: "nostr")
        }
        #expect(throws: Nip49.CryptoError.malformed) {
            try Nip49.decrypt("not even bech32", password: "nostr")
        }
    }

    @Test func passwordIsNFKCNormalized() {
        // NIP-49 §Test Data: the decomposed spelling U+212B U+2126 U+1E9B U+0323
        // must NFKC-normalize to the composed U+00C5 U+03A9 U+1E69
        // (UTF-8 c3 85 ce a9 e1 b9 a9) before scrypt.
        let norm = "\u{212B}\u{2126}\u{1E9B}\u{0323}".precomposedStringWithCompatibilityMapping
        #expect(Array(norm.utf8).map { String(format: "%02x", $0) }.joined() == "c385cea9e1b9a9")
    }
}
