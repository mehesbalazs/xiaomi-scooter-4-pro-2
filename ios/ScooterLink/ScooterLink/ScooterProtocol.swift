//  ScooterProtocol.swift
//  A t2336 MIoT SPEC keret-építése, titkosítása és a property-térkép.
//  A logika 1:1 a scooter.py-ból (build_get/build_set/enc_spec/dec_spec/PROPS).

import Foundation

// MARK: - A támogatott roller
enum ScooterModel {
    static let family = "Xiaomi Electric Scooter"
    static let variant = "4 Pro (2nd Gen)"
    static let modelId = "xiaomi.scooter.t2336"
}

// MARK: - Session-kulcsok (a HKDF 64 bájtos kimenetéből)
struct SessionKeys {
    let devKey: Data   // [0:16]  eszköz -> app
    let appKey: Data   // [16:32] app -> eszköz
    let devIv: Data    // [32:36]
    let appIv: Data    // [36:40]
    init(derived: Data) {
        let b = [UInt8](derived)
        devKey = Data(b[0..<16]); appKey = Data(b[16..<32])
        devIv = Data(b[32..<36]); appIv = Data(b[36..<40])
    }
}

// MARK: - Keret-építés
enum SpecFrame {
    /// [len|0x2000 u16][tid u16][op u8][count=1 u8]
    static func header(total: Int, tid: Int = 1, op: Int) -> Data {
        let lenflag = (total | 0x2000) & 0xFFFF
        return Data([UInt8(lenflag & 0xFF), UInt8(lenflag >> 8),
                     UInt8(tid & 0xFF), UInt8((tid >> 8) & 0xFF), UInt8(op), 1])
    }

    /// t2336 OLVASÁS: op=2, 3 bájtos leíró [siid, piid u16], érték nélkül.
    static func get(siid: Int, piid: Int, tid: Int = 1, op: Int = 2) -> Data {
        let body = Data([UInt8(siid), UInt8(piid & 0xFF), UInt8(piid >> 8)])
        return header(total: 6 + body.count, tid: tid, op: op) + body
    }

    /// t2336 ÍRÁS: op=0, leíró [siid, piid u16, típus/hossz u16, érték…].
    static func set(siid: Int, piid: Int, typeCode: Int, value: Data, tid: Int = 1) -> Data {
        let tl = (typeCode << 12) | value.count
        var body = Data([UInt8(siid), UInt8(piid & 0xFF), UInt8(piid >> 8),
                         UInt8(tl & 0xFF), UInt8((tl >> 8) & 0xFF)])
        body.append(value)
        return header(total: 6 + body.count, tid: tid, op: 0) + body
    }
}

// MARK: - SPEC titkosítás (app -> eszköz) és fejtés (eszköz -> app)
enum SpecCipher {
    static func encrypt(keys: SessionKeys, counter: Int, frame: Data) -> Data {
        var nonce = keys.appIv; nonce.append(Data(count: 4)); nonce.append(le32(counter))
        let ct = ScooterCrypto.ccmEncrypt(key: keys.appKey, nonce: nonce, plaintext: frame, tagLen: 4)
        return Data([UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF)]) + ct
    }

    static func decrypt(keys: SessionKeys, payload: Data) -> Data? {
        let b = [UInt8](payload)
        guard b.count >= 2 else { return nil }
        let counter = Int(b[0]) | (Int(b[1]) << 8)
        var nonce = keys.devIv; nonce.append(Data(count: 4)); nonce.append(le32(counter))
        return ScooterCrypto.ccmDecrypt(key: keys.devKey, nonce: nonce,
                                        ciphertext: Data(b[2...]), tagLen: 4)
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}

// MARK: - Válasz-értelmezés
enum SpecParse {
    /// A GET-válasz értékbájtjai (status==0 esetén), különben nil.
    static func getValue(_ pt: Data?) -> Data? {
        guard let p = pt.map({ [UInt8]($0) }), p.count >= 11 else { return nil }
        let status = Int(p[9]) | (Int(p[10]) << 8)
        guard status == 0, p.count >= 13 else { return nil }
        let tl = Int(p[11]) | (Int(p[12]) << 8)
        let vlen = tl & 0x0FFF
        guard p.count >= 13 + vlen else { return Data() }
        return Data(p[13 ..< 13 + vlen])
    }

    /// A SET-válasz státusza (0 = OK), vagy -1.
    static func setStatus(_ pt: Data?) -> Int {
        guard let p = pt.map({ [UInt8]($0) }), p.count >= 11 else { return -1 }
        return Int(p[9]) | (Int(p[10]) << 8)
    }
}

// MARK: - Property-térkép (forrás: desperado0044/xiaomi-scooter-link, t2336-on igazolva)
enum PropKind { case u8, u16, i8, f, bool, str }

struct PropDef {
    let name: String; let kind: PropKind; let scale: Double; let unit: String
    init(_ n: String, _ k: PropKind, _ s: Double, _ u: String) { name = n; kind = k; scale = s; unit = u }
}

enum PropValue { case number(Double), text(String) }

enum Props {
    static func key(_ s: Int, _ p: Int) -> Int { (s << 8) | p }

    static let all: [Int: PropDef] = [
        key(1, 1): PropDef("RIDING_MODE", .u8, 1, ""),
        key(1, 2): PropDef("BATTERY_LEVEL", .u8, 1, "%"),
        key(1, 3): PropDef("REMAINING_BATTERY", .u16, 1, "mAh"),
        key(1, 4): PropDef("VOLTAGE", .f, 0.01, "V"),
        key(1, 5): PropDef("CURRENT", .f, 0.01, "A"),
        key(1, 6): PropDef("POWER", .f, 0.01, "W"),
        key(1, 7): PropDef("REMAINING_MILEAGE", .f, 0.01, "km"),
        key(1, 8): PropDef("FAULT", .u8, 1, ""),
        key(1, 9): PropDef("CURRENT_MILEAGE", .f, 0.01, "km"),
        key(2, 1): PropDef("AVERAGE_SPEED", .f, 0.01, "km/h"),
        key(2, 2): PropDef("IS_LOCKED", .bool, 1, ""),
        key(2, 5): PropDef("ENERGY_RECOVERY", .u8, 1, ""),
        key(2, 6): PropDef("TOTAL_MILEAGE", .f, 0.01, "km"),
        key(2, 7): PropDef("IS_RIDING", .u8, 1, ""),
        key(2, 8): PropDef("RIDING_TIME", .f, 60, "s"),   // a roller PERCben küldi → ×60 = másodperc
        key(2, 9): PropDef("HIGHEST_SPEED", .f, 0.01, "km/h"),
        key(3, 2): PropDef("BATTERY_TEMPERATURE", .i8, 1, "°C"),
        key(3, 3): PropDef("SCOOTER_TEMPERATURE", .i8, 1, "°C"),
        key(3, 8): PropDef("ACTIVATION_DATE", .str, 1, ""),
        key(3, 11): PropDef("NUMBER_OF_CYCLES", .u8, 1, ""),
        key(3, 12): PropDef("SOH", .u8, 1, "%"),
        key(4, 2): PropDef("BATTERY_SN", .str, 1, ""),
        key(4, 4): PropDef("SCOOTER_SN", .str, 1, ""),
        key(4, 5): PropDef("FIRMWARE_VERSION", .str, 1, ""),
    ]

    static func decode(_ raw: Data?, _ def: PropDef) -> PropValue? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let b = [UInt8](raw)
        switch def.kind {
        case .str:
            let trimmed = Data(b.prefix { $0 != 0 })
            return .text(String(decoding: trimmed, as: UTF8.self))
        case .i8:
            return .number(Double(Int8(bitPattern: b[0])) * def.scale)
        case .f:
            guard b.count == 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return .number(Double(Float(bitPattern: bits)) * def.scale)
        case .u8, .u16, .bool:
            var n = 0
            for (i, byte) in b.enumerated() { n |= Int(byte) << (8 * i) }
            return .number(Double(n) * def.scale)
        }
    }
}

// MARK: - Telemetria-pillanatkép (a UI ezt mutatja és menti el)
struct Telemetry: Codable, Equatable {
    var updated: Date
    var locked: Bool?
    var battery: Int?          // %
    var rangeKm: Double?       // becsült hatótáv
    var totalKm: Double?       // össz-km
    var soh: Int?              // akku-állapot, %
    var cycles: Int?           // töltési ciklusok
    var voltage: Double?       // V
    var temperature: Int?      // roller (vezérlő) hőmérséklete, °C
    var batteryTemperature: Int?  // akku-hőmérséklet, °C
    var tripKm: Double?        // aktuális út (bekapcsolás óta), km
    var tripSeconds: Double?   // aktuális út menetideje, s

    init(updated: Date) { self.updated = updated }
}

extension PropValue {
    var int: Int? { if case .number(let d) = self { return Int(d.rounded()) }; return nil }
    var double: Double? { if case .number(let d) = self { return d }; return nil }
}
