//  ScooterService.swift  — egy roller-művelet: csatlakozás → login → parancs → bontás,
//  átmeneti hibánál újrapróbálva. Közös az app felületének és a widgetek/vezérlők
//  intentjeinek (azok is ebben a folyamatban futnak, lásd ScooterIntents.swift).

import Foundation
import WidgetKit

enum ScooterAction: Equatable { case refresh, lock, unlock }

enum ScooterOutcome {
    case lockSet(Bool)
    case telemetry(Telemetry)
}

@MainActor
final class ScooterService {
    static let shared = ScooterService()

    /// Egy művelet legfeljebb ennyi teljes (csatlakozás + login + parancs) kísérlet.
    static let maxAttempts = 3
    /// Minden művelet után (bármelyik forrásból) — a felület ebből frissül.
    static let stateChanged = Notification.Name("hu.scooterlink.stateChanged")

    let client = ScooterClient()
    private(set) var running: ScooterAction?
    /// Az utolsó művelethez szükséges kísérletek száma (1 = elsőre sikerült).
    private(set) var lastAttempts = 0
    /// Kísérlet-korlát (a mérőmód 1-re veszi, hogy a nyers hibaarány látsszon).
    var attemptsLimit = ScooterService.maxAttempts

    private init() {}

    /// `source`: a naplóban a művelet forrása (pl. „VM”, „WIDGET”). Ha épp fut egy másik
    /// művelet (pl. az appból és egy widgetről egyszerre), megvárja — a roller egyszerre
    /// egy kapcsolatot fogad.
    func perform(_ action: ScooterAction, source: String,
                 progress: ((String) -> Void)? = nil) async throws -> ScooterOutcome {
        while running != nil { try await Task.sleep(nanoseconds: 200_000_000) }
        guard let pin = Keychain.get("pin"), !pin.isEmpty,
              let key = Keychain.get("cloudkey"), !key.isEmpty else { throw ScooterError.missingCredentials }
        running = action
        defer { running = nil }
        let started = Date()
        trace("[\(source)] === \(Self.name(action)) === (kézfogás: \(client.timing.label))")
        do {
            let outcome = try await session(action, pin: pin, key: key, progress: progress)
            trace("[\(source)] → OK (\(Self.elapsed(since: started)))")
            record(outcome)
            return outcome
        } catch {
            trace("[\(source)] → HIBA (\(Self.elapsed(since: started))): \(error)")
            recordFailure(action)
            throw error
        }
    }

    private func session(_ action: ScooterAction, pin: String, key: String,
                         progress: ((String) -> Void)?) async throws -> ScooterOutcome {
        try await Retry.run(attempts: attemptsLimit, shouldRetry: Retry.isTransient) { attempt in
            let tag = attempt > 1 ? " (\(attempt)/\(attemptsLimit))" : ""
            lastAttempts = attempt
            if attempt > 1 { client.log("↻ újrapróbálás \(attempt)/\(attemptsLimit)") }
            do {
                progress?("Kapcsolódás…" + tag)
                try await client.connect()
                progress?("Bejelentkezés…" + tag)
                try await client.login(pin: pin, encryptedKeyHex: key)
                progress?(Self.workingText(action) + tag)
                let outcome: ScooterOutcome
                switch action {
                case .lock: try await client.setLocked(true); outcome = .lockSet(true)
                case .unlock: try await client.setLocked(false); outcome = .lockSet(false)
                case .refresh: outcome = .telemetry(try await client.readTelemetry())
                }
                await client.disconnect()
                return outcome
            } catch {
                client.log("✗ \(error)")
                await client.disconnect()
                throw error
            }
        }
    }

    // MARK: Közös állapot (widget) + értesítés

    private func record(_ outcome: ScooterOutcome) {
        var s = SharedState.load()
        switch outcome {
        case .lockSet(let on):
            s.locked = on; s.updated = Date()
        case .telemetry(let t):
            guard let l = t.locked else { return }
            s.locked = l; s.updated = t.updated
        }
        s.lastFailure = nil; s.lastFailureDate = nil
        SharedState.save(s)
        publish()
    }

    private func recordFailure(_ action: ScooterAction) {
        guard action != .refresh else { return }       // a widget csak a zár/nyit hibáját jelzi
        var s = SharedState.load()
        s.lastFailure = action == .lock ? "Zárás sikertelen" : "Nyitás sikertelen"
        s.lastFailureDate = Date()
        SharedState.save(s)
        publish()
    }

    private func publish() {
        WidgetCenter.shared.reloadTimelines(ofKind: "ScooterStatus")
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
    }

    // MARK: Szövegek

    static func name(_ a: ScooterAction) -> String {
        switch a {
        case .refresh: return "Adatok"
        case .lock: return "Zárás"
        case .unlock: return "Nyitás"
        }
    }

    private static func workingText(_ a: ScooterAction) -> String {
        switch a {
        case .refresh: return "Adatok olvasása…"
        case .lock: return "Zárás…"
        case .unlock: return "Nyitás…"
        }
    }

    private static func elapsed(since d: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(d))
    }
}
