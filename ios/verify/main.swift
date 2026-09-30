// A Swift kriptó- és protokoll-mag ellenőrzése a scooter.py referencia-értékei ellen.
// Futtatás:  bash run.sh   (vagy lásd a run.sh-t)
import Foundation
import CryptoKit

func hex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
extension Data { var hexstr: String { map { String(format: "%02x", $0) }.joined() } }
var pass = 0, fail = 0
func check(_ l: String, _ g: String, _ w: String) {
    if g == w { pass += 1; print("  OK   \(l)") }
    else { fail += 1; print("  FAIL \(l)\n        got:  \(g)\n        want: \(w)") }
}

print("== kriptó ==")
let ourPriv = try! P256.KeyAgreement.PrivateKey(rawRepresentation: hex(String(repeating: "11", count: 32)))
let peerPub = hex("d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285")
check("ECDH shared X", ScooterCrypto.ecdhSharedX(ourPriv: ourPriv, peerPub64: peerPub)!.hexstr,
      "ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6")
check("HKDF-SHA256", ScooterCrypto.hkdfSHA256(ikm: hex(String(repeating: "00", count: 32) + String(repeating: "aa", count: 32)),
      salt: Data("smartcfg-login-salt".utf8), info: Data("smartcfg-login-info".utf8), length: 64).hexstr,
      "648723741680d75cbf8414a177ba9de752676e58524cc505b37b1e27754641c07215fcc962afb9827b357e7ba0e2265e01315cb049e98a6dcee19f4db554e93c")
let ccmKey = hex("0123456789abcdef0123456789abcdef")
check("AES-CCM encrypt", ScooterCrypto.ccmEncrypt(key: ccmKey, nonce: hex("101112131415161718191a1b"), plaintext: hex("deadbeef"), tagLen: 4).hexstr, "5fb68e1a8f2d87e4")
check("AES-CCM decrypt", ScooterCrypto.ccmDecrypt(key: ccmKey, nonce: hex("101112131415161718191a1b"), ciphertext: hex("5fb68e1a8f2d87e4"), tagLen: 4)?.hexstr ?? "nil", "deadbeef")
check("SPEC CCM encrypt", ScooterCrypto.ccmEncrypt(key: ccmKey, nonce: hex("112233440000000005000000"), plaintext: hex("01020304050607"), tagLen: 4).hexstr, "f43eec37f7d95da34711c6")
check("CRC32 LE", ScooterCrypto.crc32leBytes(peerPub).hexstr, "cda01fd0")
check("MD5(123456)", ScooterCrypto.md5(Data("123456".utf8)).hexstr, "e10adc3949ba59abbe56e057f20f883e")
check("LTMK decrypt", ScooterCrypto.aesCBCDecryptNoPad(key: ScooterCrypto.md5(Data("123456".utf8)),
      iv: hex("7aa4c68c590d4031b980d98b41023800"), ct: hex(String(repeating: "aa", count: 32))).hexstr,
      "bf30282d49bcb24ba98e25188ac551286f3e440bba1b58d0baa45639616dc382")

print("== protokoll ==")
check("GET(1,4)", SpecFrame.get(siid: 1, piid: 4).hexstr, "092001000201010400")
check("SET lock", SpecFrame.set(siid: 2, piid: 2, typeCode: 0, value: hex("01")).hexstr, "0c2001000001020200010001")
check("SET unlock", SpecFrame.set(siid: 2, piid: 2, typeCode: 0, value: hex("00")).hexstr, "0c2001000001020200010000")
let keys = SessionKeys(derived: hex(String(repeating: "00", count: 16) + String(repeating: "11", count: 16) + "2233445566778899aabbccdd"))
check("enc_spec ctr=3", SpecCipher.encrypt(keys: keys, counter: 3, frame: hex("092001000201010400")).hexstr, "030014eb18be7c5f6a3d4ff4ed286c")
check("dec_spec ctr=7", SpecCipher.decrypt(keys: keys, payload: hex("0700cdd78969f43d87ec1d521b1324378dbdab27"))?.hexstr ?? "nil", "1120010003010104000000049000")
func num(_ v: PropValue?) -> String { if case .number(let d)? = v { return String(format: "%.2f", d) }; return "nil" }
func txt(_ v: PropValue?) -> String { if case .text(let s)? = v { return s }; return "nil" }
check("REMAINING_MILEAGE 6050->60.5", num(Props.decode(hex("0010bd45"), Props.all[Props.key(1,7)]!)), "60.50")
check("BATTERY 0x64->100", num(Props.decode(hex("64"), Props.all[Props.key(1,2)]!)), "100.00")
check("TEMP i8 0x17->23", num(Props.decode(hex("17"), Props.all[Props.key(3,2)]!)), "23.00")
check("FIRMWARE str", txt(Props.decode(hex("322e352e335f303031352e30303130"), Props.all[Props.key(4,5)]!)), "2.5.3_0015.0010")
check("RIDING_TIME 14 perc->840 s", num(Props.decode(hex("00006041"), Props.all[Props.key(2,8)]!)), "840.00")

print("== újrapróbálás ==")
/// Lefuttatja a Retry-t egy előre megadott hibasorozattal; visszaadja (eredmény, kísérletszám).
func retryScenario(_ errors: [Error], attempts: Int = 3) async -> (String, Int) {
    var calls = 0
    do {
        let r: String = try await Retry.run(attempts: attempts, delay: 0, shouldRetry: Retry.isTransient) { _ in
            calls += 1
            if calls <= errors.count { throw errors[calls - 1] }
            return "ok"
        }
        return (r, calls)
    } catch { return ("\(error)", calls) }
}
var (res, n) = await retryScenario([ScooterError.loginFailed("A4"), ScooterError.noResponse])
check("2 átmeneti hiba után siker", "\(res) @\(n)", "ok @3")
(res, n) = await retryScenario([ScooterError.timeout("x"), ScooterError.disconnected, ScooterError.noResponse, ScooterError.noResponse])
check("mindig átmeneti: 3 kísérlet, utolsó hiba", "\(res) @\(n)", "noResponse @3")
(res, n) = await retryScenario([ScooterError.rejected])
check("elutasított login: nincs újrapróbálás", "\(res) @\(n)", "rejected @1")
(res, n) = await retryScenario([ScooterError.notFound])
check("nincs roller: nincs újrapróbálás", "\(res) @\(n)", "notFound @1")
(res, n) = await retryScenario([ScooterError.commandFailed(3)])
check("parancs-státusz≠0: nincs újrapróbálás", "\(res) @\(n)", "commandFailed(3) @1")
(res, n) = await retryScenario([ScooterError.bluetoothOff])
check("BT kikapcsolva: nincs újrapróbálás", "\(res) @\(n)", "bluetoothOff @1")
(res, n) = await retryScenario([ScooterError.missingCredentials])
check("nincs PIN/kulcs: nincs újrapróbálás", "\(res) @\(n)", "missingCredentials @1")
print("== roller-jelöltek (első beállítás) ==")
func nextCand(_ e: Error, remembered: Bool, tried: Int) -> String {
    "\(Retry.shouldTryNextCandidate(after: e, remembered: remembered, tried: tried, maxCandidates: 5))"
}
check("elutasított, még nincs megjegyzett roller → következő", nextCand(ScooterError.rejected, remembered: false, tried: 1), "true")
check("elutasított, van megjegyzett roller → nem keres tovább", nextCand(ScooterError.rejected, remembered: true, tried: 1), "false")
check("elutasított, elfogytak a jelöltek → nem keres tovább", nextCand(ScooterError.rejected, remembered: false, tried: 5), "false")
check("átmeneti hiba → nem jelöltváltás (azt az újrapróbálás kezeli)", nextCand(ScooterError.loginFailed("A4"), remembered: false, tried: 1), "false")
check("nincs roller → nem jelöltváltás", nextCand(ScooterError.notFound, remembered: false, tried: 1), "false")
(res, n) = await retryScenario([CancellationError()])
check("idegen hiba: nincs újrapróbálás", "\(res) @\(n)", "CancellationError() @1")

print("== keret-sor ==")
func after(_ s: Double, _ f: @escaping @Sendable () -> Void) {
    DispatchQueue.global().asyncAfter(deadline: .now() + s, execute: f)
}
// Sorrend + puffer
let qa = FrameQueue<Int>()
qa.put(1); qa.put(2); qa.put(3)
let seq = [await qa.next(timeout: 1), await qa.next(timeout: 1), await qa.next(timeout: 1)]
check("pufferelt sorrend", "\(seq)", "[Optional(1), Optional(2), Optional(3)]")
// Időtúllépés
var t0 = Date()
let none = await qa.next(timeout: 0.2)
check("időtúllépés → nil ~0.2 s", "\(none.map(String.init) ?? "nil") \(abs(Date().timeIntervalSince(t0) - 0.2) < 0.1)", "nil true")
// Késői időzítő: egy már teljesült hívás időzítője nem ütheti ki a következő várakozót
let qb = FrameQueue<Int>()
after(0.05) { qb.put(1) }
let first = await qb.next(timeout: 0.3)          // 50 ms-nál teljesül; időzítője 300 ms-nál fut le
after(0.5) { qb.put(2) }                          // a régi időzítő lefutása UTÁN érkezik
t0 = Date()
let second = await qb.next(timeout: 2.0)
check("késői időzítő nem nyeli el a következő keretet",
      "\(first ?? -1),\(second ?? -1) \(Date().timeIntervalSince(t0) < 1.0)", "1,2 true")
// close(): a várakozó azonnal nil-t kap, a további hívások is; reopen után újra működik
let qc = FrameQueue<Int>()
after(0.1) { qc.close() }
t0 = Date()
let closedWait = await qc.next(timeout: 5)
check("close() felébreszti a várakozót", "\(closedWait.map(String.init) ?? "nil") \(Date().timeIntervalSince(t0) < 0.5)", "nil true")
qc.put(9)
t0 = Date()
let afterClose = await qc.next(timeout: 5)
check("lezárt sor: put eldobva, next azonnal nil", "\(afterClose.map(String.init) ?? "nil") \(Date().timeIntervalSince(t0) < 0.1)", "nil true")
qc.reopen(); qc.put(7)
check("reopen után újra működik", "\(await qc.next(timeout: 1).map(String.init) ?? "nil")", "7")
// Átugrás: egy késve érkező (pl. A4-) keretet eldob, és a valódi választ adja vissza
let qd = FrameQueue<Int>()
after(0.05) { qd.put(4) }      // késői A4-keret
after(0.10) { qd.put(1) }      // a várt RCV_RDY
let skipped = await qd.next(timeout: 1) { $0 == 4 }
check("átugrás: késői keret eldobva, a válasz megjön", "\(skipped ?? -1)", "1")
after(0.05) { qd.put(4) }
t0 = Date()
let onlySkipped = await qd.next(timeout: 0.3) { $0 == 4 }
check("átugrás: az időkeret összesen értendő (nem nyúlik)",
      "\(onlySkipped.map(String.init) ?? "nil") \(abs(Date().timeIntervalSince(t0) - 0.3) < 0.1)", "nil true")

print("\n\(pass) OK, \(fail) FAIL")
exit(fail == 0 ? 0 : 1)
