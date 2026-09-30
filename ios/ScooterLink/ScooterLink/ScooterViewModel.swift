//  ScooterViewModel.swift  — a UI állapota + a BLE-műveletek összekötése.

import Foundation
import Combine

@MainActor
final class ScooterViewModel: ObservableObject {
    typealias Action = ScooterAction

    @Published private(set) var running: Action?
    @Published private(set) var step = ""
    @Published var errorMessage: String?

    @Published private(set) var locked: Bool?
    @Published private(set) var lockUpdated: Date?
    @Published private(set) var telemetry: Telemetry?

    @Published private(set) var log: [String] = []
    @Published private(set) var successCount = 0     // haptikus visszajelzés triggerei
    @Published private(set) var failureCount = 0

    @Published private(set) var pin: String
    @Published private(set) var cloudKey: String
    /// Nyitáskor kapcsolja-e be a tempomatot (a vezérlő kikapcsoláskor elfelejti, ezért menetenként).
    @Published var cruiseOnUnlock: Bool {
        didSet { UserDefaults.standard.set(cruiseOnUnlock, forKey: ScooterService.cruiseOnUnlockKey) }
    }
    /// A megjegyzett (saját) roller — az első sikeres művelet után; a Beállításokban látszik.
    @Published private(set) var rememberedScooter: ScooterClient.RememberedScooter?

    var busy: Bool { running != nil }
    var hasCredentials: Bool { !pin.isEmpty && !cloudKey.isEmpty }

    private let service = ScooterService.shared
    private var client: ScooterClient { service.client }
    private var observer: NSObjectProtocol?

    init() {
        pin = Keychain.get("pin") ?? ""
        cloudKey = Keychain.get("cloudkey") ?? ""
        cruiseOnUnlock = UserDefaults.standard.bool(forKey: ScooterService.cruiseOnUnlockKey)
        restoreSnapshot()
        syncFromShared()
        client.onLog = { [weak self] line in
            Task { @MainActor in self?.pushLog(line) }
        }
        // egy widget / vezérlő is végezhetett műveletet (ugyanebben a folyamatban)
        observer = NotificationCenter.default.addObserver(forName: ScooterService.stateChanged,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncFromShared() }
        }
        let info = Bundle.main.infoDictionary
        trace("[APP] indul — v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), "
              + "megjegyzett roller: \(rememberedScooter?.name ?? "nincs")")
        #if DEBUG
        applyDemoIfRequested()
        #endif
    }

    private func pushLog(_ s: String) {
        log.append(s)
        if log.count > 150 { log.removeFirst(log.count - 150) }
    }

    /// A közös (widget-) állapotból átveszi a zárállapotot, ha az frissebb a sajátunknál —
    /// pl. ha közben egy widgetről zártak / nyitottak.
    func syncFromShared() {
        rememberedScooter = client.remembered
        let s = SharedState.load()
        guard let l = s.locked, let u = s.updated, u > (lockUpdated ?? .distantPast) else { return }
        locked = l; lockUpdated = u
        saveSnapshot()
    }

    /// A megjegyzett roller elfelejtése: a következő művelet újra keres (első beállítás).
    func forgetScooter() {
        client.forget()
        rememberedScooter = nil
    }

    // MARK: Hitelesítő adatok (Kulcskarika)
    func saveCredentials(pin newPin: String, key newKey: String) {
        let p = newPin.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = newKey.filter { !$0.isWhitespace }.lowercased()
        if p.isEmpty { Keychain.delete("pin") } else { Keychain.set("pin", p) }
        if k.isEmpty { Keychain.delete("cloudkey") } else { Keychain.set("cloudkey", k) }
        pin = p; cloudKey = k
    }

    /// A felhőkulcs formai ellenőrzése (SCOOTER_PSK_LOCAL: 64 hex karakter = 32 bájt).
    static func keyProblem(_ s: String) -> String? {
        let k = s.filter { !$0.isWhitespace }
        if k.isEmpty { return nil }
        if !k.allSatisfy(\.isHexDigit) { return "Csak hexadecimális karakter lehet (0–9, a–f)." }
        if k.count != 64 { return "64 karakter várható (most: \(k.count))." }
        return nil
    }

    // MARK: Műveletek
    func run(_ action: Action) async {
        guard running == nil else { return }
        guard hasCredentials else {
            errorMessage = "Előbb add meg a PIN-t és a felhőkulcsot a beállításokban."
            failureCount += 1
            return
        }
        running = action; errorMessage = nil; log.removeAll()
        defer { running = nil; step = "" }
        do {
            // zár/nyit: csak a parancs megy ki — adatokat nem olvasunk (az a Frissítés gomb dolga)
            let outcome = try await service.perform(action, source: "VM") { [weak self] s in self?.step = s }
            switch outcome {
            case .lockSet(let on):
                locked = on; lockUpdated = Date()
            case .telemetry(let t):
                telemetry = t
                if let l = t.locked { locked = l; lockUpdated = t.updated }
            }
            saveSnapshot()
            successCount += 1
        } catch {
            errorMessage = Self.message(for: error)
            failureCount += 1
        }
    }

    static func message(for error: Error) -> String {
        switch error as? ScooterError {
        case .bluetoothOff?:
            return "A Bluetooth ki van kapcsolva, vagy az app nem kapott hozzáférést."
        case .notFound?:
            return "Nem találom a rollert. Kapcsold be, és gyere közelebb vele."
        case .rejected?:
            return "A roller elutasította a bejelentkezést. Ellenőrizd a PIN-t és a felhőkulcsot a beállításokban."
        case .commandFailed(let s)?:
            return "A roller nem hajtotta végre a parancsot (státusz: \(s))."
        case .missingCredentials?:
            return "Előbb add meg a PIN-t és a felhőkulcsot az app beállításaiban."
        case .some:
            return "Gyenge kapcsolat — \(ScooterService.maxAttempts) próbálkozás sem sikerült. Gyere közelebb a rollerhez, és próbáld újra."
        case nil:
            return error.localizedDescription
        }
    }

    // MARK: Utolsó ismert állapot (az app újraindítása után is látszik)
    private struct Snapshot: Codable { var locked: Bool?; var lockUpdated: Date?; var telemetry: Telemetry? }
    private static let snapshotKey = "snapshot.v1"

    private func saveSnapshot() {
        let s = Snapshot(locked: locked, lockUpdated: lockUpdated, telemetry: telemetry)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.snapshotKey) }
    }
    private func restoreSnapshot() {
        guard let d = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        locked = s.locked; lockUpdated = s.lockUpdated; telemetry = s.telemetry
    }

    // MARK: - Fejlesztői kapcsolók (csak Debug build)
    #if DEBUG
    /// Szimulátoros képernyőképekhez: `-demo` mintaadatot mutat (a Kulcskarikához nem nyúl).
    private func applyDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-forgetScooter") { forgetScooter() }            // első beállítás próbája
        if args.contains("-rejectOnce") { client.debugRejections = 1 }    // jelöltváltás próbája
        if let t = args.firstIndex(of: "-timing").flatMap({ $0 + 1 < args.count ? args[$0 + 1] : nil }),
           let cfg = Self.parseTiming(t) { client.timing = cfg }        // pl. önteszt adott kézfogás-időzítéssel
        guard args.contains("-demo") else { return }
        pin = "demo"; cloudKey = "demo"
        var t = Telemetry(updated: Date().addingTimeInterval(-7 * 60))
        t.locked = true; t.battery = 78; t.rangeKm = 41.6; t.totalKm = 1234.5; t.soh = 98
        t.cycles = 23; t.voltage = 40.8; t.temperature = 24; t.batteryTemperature = 22
        t.tripKm = 4.2; t.tripSeconds = 740
        telemetry = t; locked = true; lockUpdated = t.updated
        client.remembered = .init(id: UUID(), name: "dreame scooter", since: t.updated.addingTimeInterval(-86400))
        rememberedScooter = client.remembered            // (csak demó / szimulátor)
        if args.contains("-demoBusy") { running = .unlock; step = "Bejelentkezés… (2/3)" }
        if args.contains("-renderWidgets") { WidgetPreviews.render() }
        if args.contains("-demoError") { errorMessage = Self.message(for: ScooterError.noResponse) }
        if args.contains("-demoEmpty") { telemetry = nil; locked = nil; lockUpdated = nil; pin = ""; cloudKey = "" }
    }

    /// Eszközön futó önteszt (`-selftest`, devicectl-lel indítva): telemetria, majd a JELENLEGI
    /// zárállapot újra-beállítása (fizikailag nem változik semmi) egy szimulált login-hibával —
    /// ez az újrapróbálást igazolja valódi BLE-n.
    func runSelfTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-selftest") else { return }
        trace("[TEST] önteszt indul")
        await run(.refresh)
        let t = telemetry
        trace("[TEST] telemetria: \(errorMessage ?? "OK") | zárva=\(locked.map { "\($0)" } ?? "?") "
              + "akku=\(t?.battery.map { "\($0)%" } ?? "?") hatótáv=\(t?.rangeKm.map { "\($0)" } ?? "?") "
              + "össz=\(t?.totalKm.map { "\($0)" } ?? "?") soh=\(t?.soh.map { "\($0)" } ?? "?") "
              + "ciklus=\(t?.cycles.map { "\($0)" } ?? "?") fesz=\(t?.voltage.map { "\($0)" } ?? "?") "
              + "hő=\(t?.temperature.map { "\($0)" } ?? "?") akku-hő=\(t?.batteryTemperature.map { "\($0)" } ?? "?") "
              + "út=\(t?.tripKm.map { "\($0)" } ?? "?") km/\(t?.tripSeconds.map { "\($0)" } ?? "?") s")
        guard errorMessage == nil, let l = locked else { trace("[TEST] FAIL: nincs zárállapot"); return }
        client.debugFailures = 1
        await run(l ? .lock : .unlock)
        trace("[TEST] \(l ? "zárás" : "nyitás") (azonos állapot) szimulált hibával: \(errorMessage ?? "OK")")
        trace("[TEST] önteszt vége")
    }

    /// A widget-intent útvonalának próbája (`-intentTest`): ugyanazt a kezelőt hívja, amit a
    /// widget-gomb / vezérlő — a JELENLEGI zárállapotot állítja be újra (fizikailag nem változik).
    func runIntentTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-intentTest") else { return }
        let before = SharedState.load()
        guard let l = locked ?? before.locked else { trace("[TEST] intent: FAIL, nincs ismert zárállapot"); return }
        trace("[TEST] intent: \(l ? "zárás" : "nyitás") (azonos állapot) az IntentBridge-en át")
        do {
            try await IntentBridge.run(lock: l)
            let after = SharedState.load()
            trace("[TEST] intent: OK | megosztott állapot: zárva=\(after.locked.map { "\($0)" } ?? "?"), "
                  + "frissítve=\(after.updated.map { "\($0)" } ?? "?"), hiba=\(after.lastFailure ?? "nincs")")
        } catch {
            trace("[TEST] intent: HIBA \(error)")
        }
        trace("[TEST] intent vége")
    }

    /// „400/800” → felderítés utáni / A4 utáni várakozás (ms); opcionális 3. tag: „s” = kereséssel,
    /// „d” = közvetlen csatlakozás, „d0.05” = közvetlen, ennyi mp után visszaesés a keresésre.
    static func parseTiming(_ s: String) -> ScooterClient.HandshakeTiming? {
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, let d = Double(parts[0]), let a = Double(parts[1]) else { return nil }
        var t = ScooterClient.HandshakeTiming(afterDiscovery: d / 1000, afterA4: a / 1000)
        if parts.count >= 3, parts[2].hasPrefix("d") {
            t.direct = true
            if let x = Double(parts[2].dropFirst()) { t.directTimeout = x }
        }
        return t
    }

    /// Kézfogás-mérés (`-bench N -configs "400/800,400/400" [-pause s] [-withRetry]`): N kör, a
    /// konfigurációk körbeforgó sorrendben (azonos körülmények). Minden körben a JELENLEGI
    /// zárállapot újra-beállítása — fizikailag nem változik semmi. Alapból újrapróbálás nélkül
    /// (a nyers hibaarány a kérdés); `-withRetry`: a valós használat szerint, 3 kísérlettel.
    func runBenchIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let n = arg("-bench").flatMap(Int.init), n > 0 else { return }
        let configs = (arg("-configs") ?? "400/600/d").split(separator: ",").compactMap { Self.parseTiming(String($0)) }
        guard !configs.isEmpty else { trace("[BENCH] FAIL: rossz -configs"); return }
        let pause = arg("-pause").flatMap(Double.init) ?? 1.0
        let original = client.timing
        service.attemptsLimit = args.contains("-withRetry") ? ScooterService.maxAttempts : 1
        defer { client.timing = original; service.attemptsLimit = ScooterService.maxAttempts }
        trace("[BENCH] \(n) kör, konfigurációk: \(configs.map(\.label).joined(separator: ", ")), "
              + "szünet: \(pause) s, kísérlet-korlát: \(service.attemptsLimit)")
        client.timing = original
        await run(.refresh)
        guard errorMessage == nil, let l = locked else { trace("[BENCH] FAIL: nincs zárállapot"); return }
        var times = [[Double]](repeating: [], count: configs.count)
        var fails = [Int](repeating: 0, count: configs.count), retries = fails
        for k in 0..<n {
            let c = k % configs.count
            client.timing = configs[c]
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            let t0 = Date()
            await run(l ? .lock : .unlock)
            let dt = Date().timeIntervalSince(t0)
            if errorMessage == nil { times[c].append(dt) } else { fails[c] += 1 }
            retries[c] += max(0, service.lastAttempts - 1)
            trace("[BENCH] \(k + 1)/\(n) [\(configs[c].label)]: \(errorMessage == nil ? "OK" : "HIBA") "
                  + "\(String(format: "%.2f", dt)) s, kísérlet: \(service.lastAttempts)")
        }
        let f = { (x: Double?) in x.map { String(format: "%.2f", $0) } ?? "–" }
        for (c, cfg) in configs.enumerated() {
            let t = times[c].sorted()
            trace("[BENCH] \(cfg.label): \(t.count)/\(t.count + fails[c]) OK, újrapróbálás: \(retries[c]) "
                  + "| min \(f(t.first)) / medián \(f(t.isEmpty ? nil : t[t.count / 2])) / max \(f(t.last)) s")
        }
        trace("[BENCH] vége")
    }
    #endif
}
