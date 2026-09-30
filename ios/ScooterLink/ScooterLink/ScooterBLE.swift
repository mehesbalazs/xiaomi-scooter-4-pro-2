//  ScooterBLE.swift
//  CoreBluetooth transport + login-szekvencia + SPEC-csatorna a t2336-hoz.
//  A folyamat 1:1 a scooter.py-ból (a4_handshake / login / mcu_gate / spec_request).

import Foundation
import CoreBluetooth
import CryptoKit

// MARK: - Karakterisztikák (16-bites UUID-k a fe95 service alatt)
private enum CH {
    static let service   = CBUUID(string: "FE95")
    static let control   = CBUUID(string: "0010")
    static let loginch   = CBUUID(string: "0016")
    static let specWrite = CBUUID(string: "001A")
    static let specNotify = CBUUID(string: "001B")
    static let mcuInfo   = CBUUID(string: "001C")
    static let extra17   = CBUUID(string: "0017")
    static let extra18   = CBUUID(string: "0018")
    static let all = [control, loginch, specWrite, specNotify, mcuInfo, extra17, extra18]
}

private let LOGIN_START = Data([0x20, 0x00, 0x00])
private let RCV_RDY = Data([0x00, 0x00, 0x01, 0x01])
private let RCV_OK  = Data([0x00, 0x00, 0x01, 0x00])
private let CFM_OK: UInt8 = 0x21
private let CFM_REJECT: Set<UInt8> = [0x22, 0x23]   // login elutasítva (hibás PIN / kulcs)
private let SALT = Data("smartcfg-login-salt".utf8)
private let INFO = Data("smartcfg-login-info".utf8)
private let CCM_NONCE = Data((16...27).map { UInt8($0) })
private let LTMK_IV = Data([0x7a,0xa4,0xc6,0x8c,0x59,0x0d,0x40,0x31,0xb9,0x80,0xd9,0x8b,0x41,0x02,0x38,0x00])
private let FRAME = 18
private let SCOOTER_PID = 0x403D   // t2336 MiBeacon product ID

// MARK: - Kliens
final class ScooterClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]

    private let controlQ = FrameQueue<Data>()
    private let loginQ = FrameQueue<Data>()
    private let specQ = FrameQueue<(CBUUID, Data)>()

    // delegate-callbackre váró folytatások (csak a főszálon érjük el őket, lásd onMain)
    private var poweredOn: ((Bool) -> Void)?
    private var scanResult: ((CBPeripheral) -> Void)?
    private var scanAccept: ((CBPeripheral) -> Bool)?
    private var connectedCont: ((Bool) -> Void)?
    private var discoveredCont: ((Bool) -> Void)?
    private var disconnectedCont: ((Bool) -> Void)?

    private var keys: SessionKeys?
    private var counter = 0

    /// Kapcsolódás- és kézfogás-időzítés, a telefonon mért értékekből (README-ios.md,
    /// „Kézfogás-időzítés”). A várakozások nem a keretek lecsengésére kellenek: a rollernek
    /// valóban idő kell a következő lépéshez.
    struct HandshakeTiming: Equatable {
        /// felderítés → A4. A roller a kapcsolódás után ~1,45 s-mal válaszol az A4-re, akármikor
        /// küldjük; ezen nincs mit nyerni, marad a bevált érték.
        var afterDiscovery: TimeInterval = 0.4
        /// MNG_ACK → login-kezdet. ≤ ~410 ms-nál a roller nem fogadja a logint (200 ms: 0/6,
        /// 400 ms: 5/6); 600 ms-mal 30 kör hiba nélkül → ~190 ms ráhagyás. (Korábban: 800 ms.)
        var afterA4: TimeInterval = 0.6
        /// Ismert rollerhez keresés nélkül csatlakozunk (~0,5 s-mal gyorsabb).
        var direct = true
        /// Ha a közvetlen csatlakozás ennyi alatt nem jön létre, visszaesés a keresésre
        /// (mért közvetlen csatlakozás: 0,5–2,0 s, medián 1,0 s).
        var directTimeout: TimeInterval = 4.0
        var label: String {
            "\(Int(afterDiscovery * 1000))/\(Int(afterA4 * 1000)) ms, "
                + (direct ? "közvetlen" + (directTimeout == 4.0 ? "" : " \(directTimeout) s") : "kereséssel")
        }
    }
    var timing = HandshakeTiming()

    /// A megjegyzett (saját) roller. Az első SIKERES bejelentkezés után mentődik (a Beállításokban
    /// látszik); ha van, az app csak ehhez csatlakozik — több ugyanilyen roller közelében is —, és
    /// közvetlenül, keresés nélkül (egy hirdetési ciklus, ~0,5 s megspórolva).
    struct RememberedScooter: Codable, Equatable {
        let id: UUID          // iOS CBPeripheral-azonosító (ezen a telefonon állandó)
        let name: String
        let since: Date
    }
    private static let rememberedKey = "scooter.remembered.v1"

    var remembered: RememberedScooter? {
        get {
            let d = UserDefaults.standard
            if let data = d.data(forKey: Self.rememberedKey),
               let r = try? JSONDecoder().decode(RememberedScooter.self, from: data) { return r }
            // korábbi verzió: csak az azonosítót tárolta — átvesszük megjegyzett rollerként
            if let s = d.string(forKey: "scooter.peripheralId"), let id = UUID(uuidString: s) {
                let r = RememberedScooter(id: id, name: "dreame scooter", since: Date())
                if let data = try? JSONEncoder().encode(r) { d.set(data, forKey: Self.rememberedKey) }
                d.removeObject(forKey: "scooter.peripheralId")
                return r
            }
            return nil
        }
        set {
            if let r = newValue, let data = try? JSONEncoder().encode(r) {
                UserDefaults.standard.set(data, forKey: Self.rememberedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
            }
        }
    }

    /// Az éppen csatlakoztatott roller (a sikeres bejelentkezés utáni megjegyzéshez).
    private(set) var currentId: UUID?
    private var currentName: String?

    /// Sikeres bejelentkezés után (ScooterService): ha még nincs megjegyzett roller, ez lesz az.
    func rememberCurrent() {
        guard remembered == nil, let id = currentId else { return }
        remembered = RememberedScooter(id: id, name: currentName ?? "roller", since: Date())
        log("roller megjegyezve: \(currentName ?? "roller")")
    }

    /// A megjegyzett roller elfelejtése — a következő művelet újra keres (első beállítás).
    func forget() {
        remembered = nil
        log("a megjegyzett roller elfelejtve")
    }

    #if DEBUG
    /// Teszthez: ennyi login-kísérlet szimulált átmeneti hibával bukik el (az újrapróbálás igazolására).
    var debugFailures = 0
    /// Teszthez: ennyi login-kísérletet „utasít el a roller” (a jelöltváltás igazolására).
    var debugRejections = 0
    #endif

    /// Napló-callback (a UI-nak); minden lépést kiír. A konzolra és a tartós naplóba is megy.
    var onLog: ((String) -> Void)?
    func log(_ s: String) { trace("[BLE] \(s)"); onLog?(s) }

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    /// Delegate-callbackre vár. A beállítás, a callback és a takarítás is a főszálon fut
    /// (a CBCentralManager a main queue-n kézbesít), így a folytatásokon nincs adatverseny.
    private func onMain<T>(timeout: TimeInterval, fallback: T,
                           _ setup: @escaping (@escaping (T) -> Void) -> Void,
                           cleanup: @escaping () -> Void = {}) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.main.async {
                var done = false
                let finish: (T) -> Void = { v in
                    guard !done else { return }
                    done = true; cleanup(); c.resume(returning: v)
                }
                setup(finish)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(fallback) }
            }
        }
    }

    // MARK: Kapcsolódás
    /// `excluded`: első beállításkor a már elutasító (nem saját) rollerek — ezeket kihagyjuk.
    func connect(excluding excluded: Set<UUID> = [], scanTimeout: TimeInterval = 15) async throws {
        resetSession()
        currentId = nil; currentName = nil
        if central.state != .poweredOn {
            log("Bluetooth bekapcsolására várok…")
            let ok: Bool = await onMain(timeout: 5, fallback: false) { finish in
                if self.central.state == .poweredOn { finish(true) } else { self.poweredOn = finish }
            } cleanup: { self.poweredOn = nil }
            guard ok else { throw ScooterError.bluetoothOff }
        }
        let mine = remembered
        var target: CBPeripheral?
        if timing.direct, let r = mine, let known = central.retrievePeripherals(withIdentifiers: [r.id]).first {
            log("közvetlen csatlakozás (megjegyzett roller)…")
            if await connectTo(known, timeout: timing.directTimeout) {
                target = known
            } else {
                // pl. megváltozott a roller címe, vagy épp más eszköz foglalja: vissza a kereséshez
                log("közvetlen csatlakozás nem jött létre, keresés…")
                await cancel(known)
                resetSession()
            }
        }
        if target == nil {
            log(mine == nil ? "roller keresése…" : "a megjegyzett roller keresése…")
            let found: CBPeripheral? = await onMain(timeout: scanTimeout, fallback: nil) { finish in
                // megjegyzett rollernél csak az fogadható el; első beállításkor bármelyik t2336,
                // ami még nem utasította el a kulcsot
                self.scanAccept = { p in mine.map { $0.id == p.identifier } ?? !excluded.contains(p.identifier) }
                self.scanResult = { finish($0) }
                // nil scan + szűrés a didDiscover-ben (a roller a fe95-öt a service DATA-ban hirdeti)
                self.central.scanForPeripherals(withServices: nil, options: nil)
            } cleanup: { self.scanResult = nil; self.scanAccept = nil; self.central.stopScan() }
            guard let f = found else {
                log(mine == nil ? "nincs (további) roller a közelben" : "a megjegyzett roller nincs a közelben")
                throw ScooterError.notFound
            }
            log("csatlakozás…")
            guard await connectTo(f, timeout: 10) else {
                await cancel(f)
                throw ScooterError.timeout("csatlakozás")
            }
            target = f
        }
        guard let p = target else { throw ScooterError.notFound }
        currentId = p.identifier; currentName = p.name
        log("kapcsolódva")
        let discovered: Bool = await onMain(timeout: 8, fallback: false) { finish in
            self.discoveredCont = finish
            p.discoverServices([CH.service])
        } cleanup: { self.discoveredCont = nil }
        guard discovered else { throw ScooterError.timeout("felderítés") }
        log("karakterisztikák OK (\(chars.count))")
        try await Task.sleep(nanoseconds: UInt64(timing.afterDiscovery * 1_000_000_000))
    }

    private func connectTo(_ p: CBPeripheral, timeout: TimeInterval) async -> Bool {
        peripheral = p; p.delegate = self
        return await onMain(timeout: timeout, fallback: false) { finish in
            self.connectedCont = finish
            self.central.connect(p, options: nil)
        } cleanup: { self.connectedCont = nil }
    }

    /// Függő vagy élő kapcsolat megszakítása; a rendszer jelzését röviden megvárjuk, és a
    /// `peripheral` már nil, így egy késői bontás-jelzés nem zárhatja le a következő sessiont.
    private func cancel(_ p: CBPeripheral) async {
        peripheral = nil
        _ = await onMain(timeout: 0.5, fallback: false) { finish in
            self.disconnectedCont = finish
            self.central.cancelPeripheralConnection(p)
        } cleanup: { self.disconnectedCont = nil }
    }

    /// Bontás, és megvárjuk, hogy a rendszer tényleg bontson — egy azonnali
    /// újracsatlakozás (újrapróbálás) különben félig élő kapcsolatba futhat.
    func disconnect() async {
        keys = nil
        guard let p = peripheral else { return }
        peripheral = nil
        guard p.state != .disconnected else { return }
        _ = await onMain(timeout: 3, fallback: false) { finish in
            self.disconnectedCont = finish
            self.central.cancelPeripheralConnection(p)
        } cleanup: { self.disconnectedCont = nil }
    }

    private func resetSession() {
        keys = nil; counter = 0; chars = [:]
        controlQ.reopen(); loginQ.reopen(); specQ.reopen()
    }

    /// A kapcsolat elveszett: minden várakozó azonnal nil-t kap (nem várunk végig időtúllépéseket).
    private func linkLost() {
        controlQ.close(); loginQ.close(); specQ.close()
    }

    // MARK: Írás
    private func write(_ uuid: CBUUID, _ data: Data) {
        guard let p = peripheral, let ch = chars[uuid] else { return }
        p.writeValue(data, for: ch, type: .withoutResponse)
    }

    // MARK: A4 handshake
    private func a4() async throws -> (Int, Int) {
        log("A4 →")
        write(CH.control, Data([0xA4]))
        guard let b = await loginQ.next(timeout: 4), b.count >= 6, b[0] == 0, b[1] == 0, b[2] == 0x04 else {
            throw ScooterError.loginFailed("A4: nem MNG válasz")
        }
        let pkgnum = Int(b[4]); let dmtu = Int(b[5])
        write(CH.loginch, Data([0, 0, 0x05, b[3], b[4], b[5]]))  // MNG_ACK
        // Az A4 utóforgalmát kivárjuk, és eldobjuk (különben a login egy maradék keretet
        // olvasna RCV_RDY helyett).
        // A roller ~60 ms múlva még egy A4-keretet küld, és a login-kezdetet csak némi idő
        // elteltével fogadja. Ha egy A4-keret mégis később jönne, a login-olvasás eldobja (isMNG).
        try await Task.sleep(nanoseconds: UInt64(timing.afterA4 * 1_000_000_000))
        loginQ.drain(); controlQ.drain()
        return (pkgnum, dmtu)
    }

    /// A4-kézfogás (MNG) kerete — a login egyik fázisában sem érvényes válasz.
    private func isMNG(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(3))
        return b.count == 3 && b[0] == 0 && b[1] == 0 && b[2] == 0x04
    }

    /// A következő login-keret; egy késve érkező A4-keret nem boríthatja a sorrendet.
    private func nextLoginFrame(_ timeout: TimeInterval) async -> Data? {
        await loginQ.next(timeout: timeout) { f in
            guard self.isMNG(f) else { return false }
            self.log("késői A4-keret eldobva")
            return true
        }
    }

    private func sendTyped(_ typeId: Int, _ payloadIn: Data) async throws {
        let payload = Data(payloadIn)   // 0-ról újraindexelve (a dropFirst-szelet miatt)
        let n = (payload.count + FRAME - 1) / FRAME
        write(CH.loginch, Data([0, 0, 0, UInt8(typeId), UInt8(n & 0xFF), UInt8(n >> 8)]))
        guard await nextLoginFrame(6) == RCV_RDY else { throw ScooterError.loginFailed("nem RCV_RDY") }
        var i = 0
        while i < payload.count {
            let chunk = payload.subdata(in: i ..< min(i + FRAME, payload.count))
            write(CH.loginch, Data([UInt8(i / FRAME + 1), 0]) + chunk)
            i += FRAME
        }
        guard await nextLoginFrame(6) == RCV_OK else { throw ScooterError.loginFailed("nem RCV_OK") }
    }

    private func recvTyped() async throws -> Data {
        guard let hdr = await nextLoginFrame(6), hdr.count >= 6 else { throw ScooterError.loginFailed("rövid fejléc") }
        let n = Int(hdr[4]) + 0x100 * Int(hdr[5])
        write(CH.loginch, RCV_RDY)
        var buf = Data()
        for _ in 0..<n {
            guard let f = await nextLoginFrame(6), f.count > 2 else { throw ScooterError.loginFailed("hiányzó keret") }
            buf.append(f.subdata(in: 2 ..< f.count))
        }
        write(CH.loginch, RCV_OK)
        return buf
    }

    // MARK: Login
    /// A PIN-nel kifejti az LTMK-t a titkosított felhőkulcsból, majd securitychip login.
    func login(pin: String, encryptedKeyHex: String) async throws {
        #if DEBUG
        if debugFailures > 0 {
            debugFailures -= 1
            log("🧪 szimulált login-hiba (teszt)")
            throw ScooterError.loginFailed("szimulált A4-hiba")
        }
        if debugRejections > 0 {
            debugRejections -= 1
            log("🧪 szimulált elutasítás (teszt)")
            throw ScooterError.rejected
        }
        #endif
        let (pkg, dmtu) = try await a4()
        log("A4 OK (pkg=\(pkg), dmtu=\(dmtu))")
        let md5 = ScooterCrypto.md5(Data(pin.utf8))
        let ltmk = ScooterCrypto.aesCBCDecryptNoPad(key: md5, iv: LTMK_IV, ct: Data(hex: encryptedKeyHex))
        let priv = P256.KeyAgreement.PrivateKey()
        let ourPub = ScooterCrypto.publicKey64(priv)
        write(CH.control, LOGIN_START)
        try await sendTyped(3, ourPub)
        let remote = try await recvTyped()
        log("roller pubkey \(remote.count)B")
        guard remote.count == 64 else { throw ScooterError.loginFailed("rossz roller pubkey") }
        guard let shared = ScooterCrypto.ecdhSharedX(ourPriv: priv, peerPub64: remote) else {
            throw ScooterError.loginFailed("ECDH hiba")
        }
        let derived = ScooterCrypto.hkdfSHA256(ikm: shared + ltmk, salt: SALT, info: INFO, length: 64)
        let crc = ScooterCrypto.crc32leBytes(remote)
        let proof = ScooterCrypto.ccmEncrypt(key: derived.subdata(in: 16..<32), nonce: CCM_NONCE, plaintext: crc, tagLen: 4)
        try await sendTyped(5, proof)
        guard let cfm = await controlQ.next(timeout: 8) else {
            throw ScooterError.loginFailed("nincs login-visszaigazolás")
        }
        guard cfm.first == CFM_OK else {
            log("login ELUTASÍTVA: \(cfm.hexstr)")
            if let c = cfm.first, CFM_REJECT.contains(c) { throw ScooterError.rejected }
            throw ScooterError.loginFailed("váratlan válasz: \(cfm.hexstr)")
        }
        log("✅ login OK")
        keys = SessionKeys(derived: derived)
        counter = 0
        await mcuGate()
        log("gate kész")
    }

    private func mcuGate() async {
        write(CH.mcuInfo, Data([0, 0])); _ = await nextMCU(3)
        write(CH.mcuInfo, Data([1, 0])); _ = await nextMCU(3)
        specQ.drain()
    }
    private func nextMCU(_ t: TimeInterval) async -> Data? {
        let deadline = Date().addingTimeInterval(t)
        while Date() < deadline {
            guard let (src, b) = await specQ.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) else { return nil }
            if src == CH.mcuInfo { return b }
        }
        return nil
    }

    // MARK: SPEC kérés (CTR/ACK/seq), a scooter.py spec_request portja
    func specRequest(_ frame: Data, timeout: TimeInterval = 5) async -> Data? {
        guard let keys = keys else { return nil }
        let payload = Data(SpecCipher.encrypt(keys: keys, counter: counter, frame: frame))
        counter += 1
        var chunks: [Data] = []
        var i = 0
        while i < payload.count { chunks.append(payload.subdata(in: i ..< min(i + FRAME, payload.count))); i += FRAME }
        let fc = chunks.count
        specQ.drain()   // korábbi kérés maradék kereteinek eltakarítása (desync ellen)
        write(CH.specWrite, Data([0, 0, 0x00, 0x00, UInt8(fc & 0xFF), UInt8(fc >> 8)]))  // CTR
        log("SPEC CTR (fc=\(fc))")
        var resp: [Int: Data] = [:]
        var respFc: Int? = nil
        var sent = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let (src, b) = await specQ.next(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
            log("<- \(src.uuidString.suffix(4)) \(b.hexstr)")
            let bb = [UInt8](b)
            let isCtrl = bb.count >= 3 && bb[0] == 0 && bb[1] == 0
            if isCtrl && bb[2] == 0x01 {  // ACK
                let status = bb.count > 3 ? Int(bb[3]) : -1
                if status == 0x01 && !sent {
                    sent = true
                    for n in 1...fc {
                        write(CH.specWrite, Data([UInt8(n & 0xFF), UInt8(n >> 8)]) + chunks[n - 1])
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                } else if status == 0x05 {  // MNG_ACK: seq-újraküldés
                    var k = 4
                    while k + 1 < bb.count {
                        let seq = Int(bb[k]) | (Int(bb[k + 1]) << 8)
                        if seq >= 1 && seq <= fc {
                            write(CH.specWrite, Data([UInt8(seq & 0xFF), UInt8(seq >> 8)]) + chunks[seq - 1])
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        k += 2
                    }
                }
            } else if isCtrl && bb[2] == 0x00 {  // válasz-CTR
                respFc = bb.count >= 6 ? (Int(bb[4]) | (Int(bb[5]) << 8)) : (bb.count > 4 ? Int(bb[4]) : 0)
                write(src, Data([0, 0, 0x01, 1]))  // ACK
            } else if !isCtrl && bb.count >= 2 {
                let seq = Int(bb[0]) | (Int(bb[1]) << 8)
                if seq >= 1 { resp[seq] = b.subdata(in: 2 ..< b.count) }
                if let fcn = respFc, resp.count >= fcn {
                    write(src, Data([0, 0, 0x01, 0]))  // ACK vége
                    var assembled = Data()
                    for key in resp.keys.sorted() { assembled.append(resp[key]!) }
                    log("✅ SPEC válasz \(assembled.count)B")
                    return SpecCipher.decrypt(keys: keys, payload: assembled)
                }
            }
        }
        log("⏱️ nincs SPEC válasz")
        return nil
    }

    func specRequestRetry(_ frame: Data, timeout: TimeInterval = 5) async -> Data? {
        if let pt = await specRequest(frame, timeout: timeout) { return pt }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await specRequest(frame, timeout: timeout)
    }

    // MARK: Magas szintű API
    /// Egy property olvasása. Ha a roller egyáltalán nem válaszol, a session halott → noResponse
    /// (az újrapróbálás újracsatlakozik). Nem támogatott / hibás státuszú property → nil.
    func read(_ siid: Int, _ piid: Int) async throws -> PropValue? {
        guard let pt = await specRequestRetry(SpecFrame.get(siid: siid, piid: piid)) else {
            throw ScooterError.noResponse
        }
        guard let def = Props.all[Props.key(siid, piid)] else { return nil }
        return Props.decode(SpecParse.getValue(pt), def)
    }

    /// Zárás (true) / nyitás (false). Idempotens, ezért biztonságosan újrapróbálható.
    func setLocked(_ on: Bool) async throws {
        let pt = await specRequestRetry(SpecFrame.set(siid: 2, piid: 2, typeCode: 0, value: Data([on ? 1 : 0])))
        guard pt != nil else { throw ScooterError.noResponse }
        let status = SpecParse.setStatus(pt)
        guard status == 0 else { throw ScooterError.commandFailed(status) }
    }

    /// Tempomat (CRUISE_IS_ON, 2/3) bekapcsolása nyitás után. Best-effort: a vezérlő minden
    /// kikapcsoláskor visszaállítja „ki”-re (régió/hardver), ezért a beállítás menetenként él;
    /// ha nem sikerül, a nyitás attól még érvényes — itt sosem dobunk hibát.
    func enableCruise() async {
        let pt = await specRequestRetry(SpecFrame.set(siid: 2, piid: 3, typeCode: 0, value: Data([1])))
        let status = pt.map { SpecParse.setStatus($0) } ?? -1
        log(status == 0 ? "tempomat bekapcsolva (nyitás után)"
                        : "tempomat beállítás nem sikerült (státusz \(status))")
    }

    /// A műszerfal adatai egy menetben (a property-térkép: ScooterProtocol.swift / README).
    func readTelemetry() async throws -> Telemetry {
        var t = Telemetry(updated: Date())
        t.locked      = try await read(2, 2)?.int.map { $0 == 1 }
        t.battery     = try await read(1, 2)?.int
        t.rangeKm     = try await read(1, 7)?.double
        t.tripKm      = try await read(1, 9)?.double
        t.tripSeconds = try await read(2, 8)?.double
        t.totalKm     = try await read(2, 6)?.double
        t.soh         = try await read(3, 12)?.int
        t.cycles      = try await read(3, 11)?.int
        t.voltage     = try await read(1, 4)?.double
        t.batteryTemperature = try await read(3, 2)?.int
        t.temperature = try await read(3, 3)?.int
        t.updated = Date()
        return t
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            poweredOn?(true)
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            poweredOn?(false)
            connectedCont?(false)
            linkLost()
        default:
            break
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let report = scanResult else { return }
        // A fe95-öt több Xiaomi eszköz hirdeti (pl. a mérleg). A MiBeacon service
        // data 2-3. bájtja a product ID (LE); a t2336 roller = 0x403D (16445).
        guard let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let mb = sd[CH.service] else { return }
        let b = [UInt8](mb)
        guard b.count >= 4 else { return }
        let pid = Int(b[2]) | (Int(b[3]) << 8)
        guard pid == SCOOTER_PID else {
            log("kihagyva: \(p.name ?? "névtelen") pid=0x\(String(pid, radix: 16))")
            return
        }
        if let accept = scanAccept, !accept(p) { return }     // nem a megjegyzett / már elutasított
        log("talált roller: \(p.name ?? "névtelen") (rssi \(RSSI))")
        report(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { connectedCont?(true) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectedCont?(false)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if let done = disconnectedCont { done(true); return }   // mi bontottunk
        guard let cur = peripheral, cur === p else { return }  // egy korábbi session késői jelzése
        log("⚠️ a kapcsolat megszakadt\(error.map { ": \($0.localizedDescription)" } ?? "")")
        connectedCont?(false)
        linkLost()
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == CH.service }) else { discoveredCont?(false); return }
        p.discoverCharacteristics(CH.all, for: svc)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            chars[ch.uuid] = ch
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
        }
        discoveredCont?(true)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { log("feliratkozás hiba \(ch.uuid.uuidString): \(error.localizedDescription)") }
        else { log("értesítés aktív: \(ch.uuid.uuidString)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        switch ch.uuid {
        case CH.control: log("⇠ \(ch.uuid.uuidString) \(v.hexstr)"); controlQ.put(v)
        case CH.loginch: log("⇠ \(ch.uuid.uuidString) \(v.hexstr)"); loginQ.put(v)
        default: specQ.put((ch.uuid, v))
        }
    }
}

private extension Data {
    var hexstr: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            if let b = UInt8(hex[i..<j], radix: 16) { d.append(b) }
            i = j
        }
        self = d
    }
}
