import Foundation
import CryptoKit
import CommonCrypto

/// NIP-49 private key encryption — decrypt `ncryptsec1…` backup keys.
///
/// Spec: bech32 (hrp `ncryptsec`) over exactly 91 bytes:
///   `[0x02 version][log_n][16B salt][24B nonce][key-security byte][XChaCha20-Poly1305 ct+tag (48B)]`
/// The symmetric key is `scrypt(NFKC(password), salt, N = 1 << log_n, r = 8, p = 1)` → 32 bytes.
/// XChaCha20-Poly1305 (libsodium construction): subkey = HChaCha20(key, nonce[0..<16]),
/// then RFC 8439 ChaCha20-Poly1305 with nonce `0x00000000 ‖ nonce[16..<24]`,
/// AAD = the key-security byte, plaintext = the 32-byte private key.
nonisolated enum Nip49 {

    enum CryptoError: Error, Equatable {
        case malformed
        case unsupportedVersion
        case invalidLogN
        case wrongPassword
        case kdfFailed
    }

    /// Decrypts an `ncryptsec1…` string with its password and returns the
    /// 32-byte private key.
    static func decrypt(_ ncryptsec: String, password: String) throws -> [UInt8] {
        let trimmed = ncryptsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (hrp, data) = Bech32.decode(trimmed),
              hrp == "ncryptsec", data.count == 91 else {
            throw CryptoError.malformed
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x02 else { throw CryptoError.unsupportedVersion }
        let logN = Int(bytes[1])
        guard (1...22).contains(logN) else { throw CryptoError.invalidLogN }
        let salt = Array(bytes[2..<18])
        let nonce = Array(bytes[18..<42])
        let keySecurity = bytes[42]
        let ciphertext = Array(bytes[43...])

        // NFKC-normalize the password so it stretches to the same scrypt
        // input no matter what keyboard produced it (spec: "ÅΩẛ̣" test).
        let normalized = password.precomposedStringWithCompatibilityMapping
        let key = try scrypt(password: Array(normalized.utf8),
                             salt: salt, logN: logN, r: 8, p: 1, dkLen: 32)

        let subkey = hChaCha20(key: key, nonce: Array(nonce[0..<16]))
        var polyNonce = [UInt8](repeating: 0, count: 4)
        polyNonce.append(contentsOf: nonce[16..<24])

        let sealed = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Data(polyNonce)),
            ciphertext: Data(ciphertext.dropLast(16)),
            tag: Data(ciphertext.suffix(16))
        )
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                sealed,
                using: SymmetricKey(data: Data(subkey)),
                authenticating: Data([keySecurity])
            )
        } catch {
            throw CryptoError.wrongPassword
        }
        guard plaintext.count == 32 else { throw CryptoError.malformed }
        return [UInt8](plaintext)
    }

    // MARK: - scrypt (RFC 7914)

    static func scrypt(password: [UInt8], salt: [UInt8], logN: Int, r: Int, p: Int, dkLen: Int) throws -> [UInt8] {
        let n = 1 << logN
        let chunkWords = 32 * r
        // PBKDF2-HMAC-SHA256(P, S, 1, p * 128 * r)
        var words = Array(try pbkdf2Sha256(password: password, salt: salt, iterations: 1, keyLength: p * chunkWords * 4))
            .littleEndianWords()
        for i in 0..<p {
            let start = i * chunkWords
            words.replaceSubrange(start..<start + chunkWords, with: romix(Array(words[start..<start + chunkWords]), n: n, r: r))
        }
        return Array(try pbkdf2Sha256(password: password, salt: words.littleEndianBytes(), iterations: 1, keyLength: dkLen))
    }

    /// ROMix over one `128 * r`-byte chunk (r salsa-blocks × 2 of 16 words).
    private static func romix(_ chunk: [UInt32], n: Int, r: Int) -> [UInt32] {
        var v: [[UInt32]] = []
        v.reserveCapacity(n)
        var x = chunk
        for _ in 0..<n {
            v.append(x)
            x = blockMix(x, r: r)
        }
        for _ in 0..<n {
            let last = x.count - 16
            // Integerify: the last 64-byte block's first 8 bytes as LE64 —
            // the second word lands in the HIGH half.
            let j = (UInt64(x[last + 1]) << 32 | UInt64(x[last])) % UInt64(n)
            let mixed = zip(x, v[Int(j)]).map { $0 ^ $1 }
            x = blockMix(mixed, r: r)
        }
        return x
    }

    /// BlockMix_salsa8: alternate 16-word salsa blocks, then split even/odd.
    private static func blockMix(_ block: [UInt32], r: Int) -> [UInt32] {
        var x = Array(block[(2 * r - 1) * 16..<2 * r * 16])
        var y: [[UInt32]] = []
        y.reserveCapacity(2 * r)
        for i in 0..<(2 * r) {
            let bi = Array(block[i * 16..<(i + 1) * 16])
            x = salsa208(zip(x, bi).map { $0 ^ $1 })
            y.append(x)
        }
        var out = [UInt32]()
        out.reserveCapacity(32 * r)
        for i in stride(from: 0, to: 2 * r, by: 2) { out.append(contentsOf: y[i]) }
        for i in stride(from: 1, to: 2 * r, by: 2) { out.append(contentsOf: y[i]) }
        return out
    }

    /// Salsa20/8 core with feed-forward addition (scrypt's variant, 8 rounds).
    private static func salsa208(_ input: [UInt32]) -> [UInt32] {
        var x = input
        for _ in 0..<4 {
            // column round
            x[4] ^= rotl(x[0] &+ x[12], 7);  x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7);   x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)
            // row round
            x[1] ^= rotl(x[0] &+ x[3], 7);   x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13);  x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7);   x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13);  x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
        return zip(x, input).map { $0 &+ $1 }
    }

    private static func pbkdf2Sha256(password: [UInt8], salt: [UInt8], iterations: UInt32, keyLength: Int) throws -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw CryptoError.kdfFailed }
        return derived
    }

    // MARK: - HChaCha20 (RFC draft-irtf-cfrg-xchacha §2.2)

    /// Derives the XChaCha subkey: ChaCha20 block function on (key, nonce[0..<16])
    /// with no feed-forward, keeping words 0–3 and 12–15.
    private static func hChaCha20(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var s: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
        s += key.littleEndianWords()
        s += Array(nonce[0..<16]).littleEndianWords()

        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        var out = [UInt32](s[0..<4])
        out.append(contentsOf: s[12..<16])
        return Data(out.littleEndianBytes()).map { $0 }
    }
}

private extension Array where Element == UInt8 {
    /// Little-endian byte → UInt32 array (crypto input packing).
    func littleEndianWords() -> [UInt32] {
        var words = [UInt32]()
        words.reserveCapacity(count / 4)
        var word: UInt32 = 0
        for (i, byte) in enumerated() {
            word |= UInt32(byte) << (8 * (i % 4))
            if i % 4 == 3 {
                words.append(word)
                word = 0
            }
        }
        return words
    }
}

private extension Array where Element == UInt32 {
    /// UInt32 array → little-endian bytes (crypto output packing).
    func littleEndianBytes() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count * 4)
        for word in self {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }
}

private func rotl(_ value: UInt32, _ shift: UInt32) -> UInt32 {
    (value << shift) | (value >> (32 - shift))
}
