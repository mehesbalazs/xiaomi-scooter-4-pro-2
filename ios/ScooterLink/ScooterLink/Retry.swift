//  Retry.swift  — hibaosztályozás és újrapróbálás (UI- és BLE-független, a verify-ban tesztelve).

import Foundation

enum ScooterError: Error, Equatable {
    case bluetoothOff               // BT kikapcsolva / nincs engedély / nem támogatott
    case notFound                   // a scan nem találta a rollert
    case timeout(String)            // csatlakozás / felderítés időtúllépés
    case loginFailed(String)        // a login-folyamat félbeszakadt (gyenge jel)
    case rejected                   // a roller elutasította a logint (hibás PIN / kulcs)
    case noResponse                 // nincs SPEC-válasz (a session elhalt)
    case commandFailed(Int)         // a roller nem-0 státusszal válaszolt a parancsra
    case disconnected               // a kapcsolat menet közben megszakadt
    case missingCredentials         // nincs PIN vagy felhőkulcs a Kulcskarikában

    /// Átmeneti hiba: újracsatlakozás + újra-login megoldhatja.
    /// A rejected-et szándékosan nem próbáljuk újra (hibás PIN-nel nem ismételgetünk).
    var isTransient: Bool {
        switch self {
        case .timeout, .loginFailed, .noResponse, .disconnected: return true
        case .bluetoothOff, .notFound, .rejected, .commandFailed, .missingCredentials: return false
        }
    }
}

enum Retry {
    /// Az `op`-ot legfeljebb `attempts`-szer futtatja (1-től számozott kísérlettel);
    /// csak akkor próbál újra, ha `shouldRetry` igaz a hibára. Az utolsó hibát dobja tovább.
    static func run<T>(attempts: Int, delay: TimeInterval = 1.0,
                       shouldRetry: (Error) -> Bool,
                       _ op: (Int) async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await op(attempt) }
            catch {
                guard attempt < attempts, shouldRetry(error) else { throw error }
                attempt += 1
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool { (error as? ScooterError)?.isTransient ?? false }

    /// Első beállításkor (még nincs megjegyzett roller) egy talált roller elutasította a
    /// bejelentkezést: valószínűleg egy másik, ugyanilyen roller — a következővel próbálkozunk
    /// (legfeljebb `maxCandidates`-ig). Megjegyzett rollernél az elutasítás hibás PIN-t / kulcsot
    /// jelent, ott nem keresünk tovább.
    static func shouldTryNextCandidate(after error: Error, remembered: Bool,
                                       tried: Int, maxCandidates: Int) -> Bool {
        guard case ScooterError.rejected? = error as? ScooterError else { return false }
        return !remembered && tried < maxCandidates
    }
}
