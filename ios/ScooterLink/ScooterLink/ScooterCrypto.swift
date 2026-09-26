//  ScooterCrypto.swift
//  A Xiaomi t2336 securitychip protokoll kriptó-magja iOS-re.
//  Csak Apple-keretek: CryptoKit (ECDH/HKDF/MD5) + CommonCrypto (AES-ECB/CBC).
//  Az AES-CCM (tag=4) saját implementáció az AES-ECB-re építve (RFC 3610),
//  mert a CryptoKit nem tud CCM-et. A scooter.py-val bájtra egyező (lásd tesztek).

import Foundation
import CryptoKit
import CommonCrypto

enum ScooterCrypto {

    // MARK: - AES-ECB (egy blokk, a CCM/CTR alapja)
    static func aesECBEncryptBlock(key: Data, block: Data) -> Data {
        precondition(block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { kp in
            block.withUnsafeBytes { bp in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        kp.baseAddress, key.count, nil,
                        bp.baseAddress, 16, &out, 16, &moved)
            }
        }
        precondition(status == kCCSuccess && moved == 16)
        return Data(out)
    }

    // MARK: - AES-CBC dekódolás padding nélkül (LTMK a PIN-ből)
    static func aesCBCDecryptNoPad(key: Data, iv: Data, ct: Data) -> Data {
        var out = [UInt8](repeating: 0, count: ct.count + 16)
        var moved = 0
        let status = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { ivp in
                ct.withUnsafeBytes { cp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),  // CBC, no padding
                            kp.baseAddress, key.count, ivp.baseAddress,
                            cp.baseAddress, ct.count, &out, out.count, &moved)
                }
            }
        }
        precondition(status == kCCSuccess)
        return Data(out.prefix(moved))
    }

    // MARK: - AES-CCM (RFC 3610), nincs AAD; tetszőleges nonce-hossz, tagLen bájt tag
    private static func ccmXor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    private static func ccmBlocks(_ data: Data) -> [Data] {
        var blocks: [Data] = []
        var i = 0
        while i < data.count {
            var block = data.subdata(in: i ..< min(i + 16, data.count))
            if block.count < 16 { block.append(Data(repeating: 0, count: 16 - block.count)) }
            blocks.append(block)
            i += 16
        }
        return blocks
    }

    /// CCM titkosítás: visszaad ciphertext || tag (tagLen bájt).
    static func ccmEncrypt(key: Data, nonce: Data, plaintext: Data, tagLen: Int = 4) -> Data {
        let M = tagLen
        let L = 15 - nonce.count
        // B0 = flags || nonce || msgLen(L bájt, big-endian)
        let flags0 = UInt8(((M - 2) / 2) << 3 | (L - 1))
        var b0 = Data([flags0]); b0.append(nonce)
        b0.append(lenBytes(plaintext.count, L))
        // CBC-MAC
        var x = aesECBEncryptBlock(key: key, block: b0)  // X1 = E(B0), mert X0=0
        for block in ccmBlocks(plaintext) {
            x = aesECBEncryptBlock(key: key, block: ccmXor(x, block))
        }
        let tag = x.prefix(M)
        // CTR: A0 a taghez, A1.. az adathoz
        let flagsCtr = UInt8(L - 1)
        func ctrBlock(_ i: Int) -> Data {
            var a = Data([flagsCtr]); a.append(nonce); a.append(lenBytes(i, L))
            return aesECBEncryptBlock(key: key, block: a)
        }
        let s0 = ctrBlock(0)
        let u = ccmXor(Data(tag), s0.prefix(M))  // titkosított tag
        var ct = Data()
        for (idx, block) in ccmBlocks(plaintext).enumerated() {
            let si = ctrBlock(idx + 1)
            ct.append(ccmXor(block, si))
        }
        ct = ct.prefix(plaintext.count) + u
        return ct
    }

    /// CCM dekódolás: bemenet ciphertext || tag; nil ha a tag nem stimmel.
    static func ccmDecrypt(key: Data, nonce: Data, ciphertext: Data, tagLen: Int = 4) -> Data? {
        let M = tagLen
        guard ciphertext.count >= M else { return nil }
        let L = 15 - nonce.count
        let ct = ciphertext.prefix(ciphertext.count - M)
        let u = ciphertext.suffix(M)
        let flagsCtr = UInt8(L - 1)
        func ctrBlock(_ i: Int) -> Data {
            var a = Data([flagsCtr]); a.append(nonce); a.append(lenBytes(i, L))
            return aesECBEncryptBlock(key: key, block: a)
        }
        // CTR-dekódolás -> plaintext
        var pt = Data()
        for (idx, block) in ccmBlocks(Data(ct)).enumerated() {
            let si = ctrBlock(idx + 1)
            pt.append(ccmXor(block, si))
        }
        pt = pt.prefix(ct.count)
        // CBC-MAC újraszámítás a plaintexten
        let flags0 = UInt8(((M - 2) / 2) << 3 | (L - 1))
        var b0 = Data([flags0]); b0.append(nonce); b0.append(lenBytes(pt.count, L))
        var x = aesECBEncryptBlock(key: key, block: b0)
        for block in ccmBlocks(Data(pt)) {
            x = aesECBEncryptBlock(key: key, block: ccmXor(x, block))
        }
        let s0 = ctrBlock(0)
        let expectedU = ccmXor(x.prefix(M), s0.prefix(M))
        guard Data(expectedU) == Data(u) else { return nil }
        return Data(pt)
    }

    private static func lenBytes(_ value: Int, _ count: Int) -> Data {
        var v = value
        var bytes = [UInt8](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0xFF); v >>= 8
        }
        return Data(bytes)
    }

    // MARK: - HKDF-SHA256
    static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - ECDH P-256 (a közös titok X-koordinátája, 32 bájt)
    static func ecdhSharedX(ourPriv: P256.KeyAgreement.PrivateKey, peerPub64: Data) -> Data? {
        var x963 = Data([0x04]); x963.append(peerPub64)  // 0x04 || X || Y
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: x963),
              let secret = try? ourPriv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return secret.withUnsafeBytes { Data($0) }
    }

    /// A saját publikus kulcs 64 bájton (X || Y, a 0x04 prefix nélkül).
    static func publicKey64(_ priv: P256.KeyAgreement.PrivateKey) -> Data {
        Data(priv.publicKey.x963Representation.dropFirst())  // 0-ról újraindexelt másolat
    }

    // MARK: - MD5 (a PIN -> AES-128 kulcs)
    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    // MARK: - CRC32 (zlib-kompatibilis, IEEE 802.3)
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return ~crc
    }

    /// CRC32 little-endian 4 bájton (a login-proof plaintextje).
    static func crc32leBytes(_ data: Data) -> Data {
        let c = crc32(data)
        return Data([UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)])
    }
}
