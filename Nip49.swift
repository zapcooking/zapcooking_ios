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

    @_optimize(speed)
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
    /// Scratch buffers are hoisted and the hot loops run over raw pointers:
    /// at log_n 16 this is ~2M salsa invocations, and Debug builds stayed
    /// 200× slower than reference implementations until bounds-checked
    /// Array subscripts came out of the inner loops.
    @_optimize(speed)
    private static func romix(_ chunk: [UInt32], n: Int, r: Int) -> [UInt32] {
        let blockWords = 32 * r
        var v = [UInt32](repeating: 0, count: n * blockWords)
        var x = chunk
        var out = [UInt32](repeating: 0, count: blockWords)
        var xb = [UInt32](repeating: 0, count: 16)
        var t = [UInt32](repeating: 0, count: 16)
        v.withUnsafeMutableBufferPointer { vp in
            x.withUnsafeMutableBufferPointer { xp in
                out.withUnsafeMutableBufferPointer { op in
                    xb.withUnsafeMutableBufferPointer { xbp in
                        t.withUnsafeMutableBufferPointer { tp in
                            guard let vp = vp.baseAddress, let xp = xp.baseAddress,
                                  let op = op.baseAddress, let xbp = xbp.baseAddress,
                                  let tp = tp.baseAddress else { return }
                                for i in 0..<n {
                                    (vp + i * blockWords).update(from: xp, count: blockWords)
                                    blockMix(block: xp, out: op, xb: xbp, t: tp, r: r)
                                }
                                for _ in 0..<n {
                                    let last = blockWords - 16
                                    // Integerify: the last 64-byte block's first
                                    // 8 bytes as LE64 — second word in the HIGH half.
                                    let j = Int((UInt64(xp[last + 1]) << 32 | UInt64(xp[last])) % UInt64(n))
                                    let base = j * blockWords
                                    for k in 0..<blockWords { xp[k] ^= vp[base + k] }
                                    blockMix(block: xp, out: op, xb: xbp, t: tp, r: r)
                                }
                        }
                    }
                }
            }
        }
        return x
    }

    /// BlockMix_salsa8 over raw pointers: even-index results fill the first
    /// r blocks of `out`, odd-index the second; `out` copies back over `block`.
    @_optimize(speed)
    private static func blockMix(block: UnsafeMutablePointer<UInt32>, out: UnsafeMutablePointer<UInt32>, xb: UnsafeMutablePointer<UInt32>, t: UnsafeMutablePointer<UInt32>, r: Int) {
        xb.update(from: block + (2 * r - 1) * 16, count: 16)
        for i in 0..<(2 * r) {
            let off = i * 16
            for k in 0..<16 { t[k] = xb[k] ^ block[off + k] }
            salsa208(t)
            let dest = (i % 2 == 0 ? i / 2 : r + (i - 1) / 2) * 16
            (out + dest).update(from: t, count: 16)
            xb.update(from: t, count: 16)
        }
        block.update(from: out, count: 32 * r)
    }

    /// Salsa20/8 core with feed-forward addition (scrypt's variant, 8 rounds),
    /// in place: result lands back in `t`, `s` is 16 words of scratch. The
    /// state is held in locals for the rounds — subscript bounds checks are
    /// what kept Debug builds ~200× slower than reference scrypts.
    @inline(__always)
    @_optimize(speed)
    private static func salsa208(_ t: UnsafeMutablePointer<UInt32>) {
        var x0 = t[0]
        var x1 = t[1]
        var x2 = t[2]
        var x3 = t[3]
        var x4 = t[4]
        var x5 = t[5]
        var x6 = t[6]
        var x7 = t[7]
        var x8 = t[8]
        var x9 = t[9]
        var x10 = t[10]
        var x11 = t[11]
        var x12 = t[12]
        var x13 = t[13]
        var x14 = t[14]
        var x15 = t[15]
        // salsa20/8: column + row, repeated 4×
// column round
            x4 ^= rotl(x0 &+ x12, 7);  x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);   x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            // row round
            x1 ^= rotl(x0 &+ x3, 7);   x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);  x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);   x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);  x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
// column round
            x4 ^= rotl(x0 &+ x12, 7);  x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);   x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            // row round
            x1 ^= rotl(x0 &+ x3, 7);   x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);  x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);   x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);  x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
// column round
            x4 ^= rotl(x0 &+ x12, 7);  x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);   x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            // row round
            x1 ^= rotl(x0 &+ x3, 7);   x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);  x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);   x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);  x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
// column round
            x4 ^= rotl(x0 &+ x12, 7);  x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);   x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            // row round
            x1 ^= rotl(x0 &+ x3, 7);   x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);  x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);   x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);  x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        t[0] &+= x0
        t[1] &+= x1
        t[2] &+= x2
        t[3] &+= x3
        t[4] &+= x4
        t[5] &+= x5
        t[6] &+= x6
        t[7] &+= x7
        t[8] &+= x8
        t[9] &+= x9
        t[10] &+= x10
        t[11] &+= x11
        t[12] &+= x12
        t[13] &+= x13
        t[14] &+= x14
        t[15] &+= x15
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

@inline(__always)
private func rotl(_ value: UInt32, _ shift: UInt32) -> UInt32 {
    (value << shift) | (value >> (32 - shift))
}
