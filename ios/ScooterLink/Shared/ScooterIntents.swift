//  ScooterIntents.swift  — zárás / nyitás App Intentként (widget-gomb, vezérlő, Parancsok app).
//
//  LiveActivityIntent: a rendszer az app folyamatában futtatja (szükség esetén a háttérben
//  elindítva) — a widget-bővítmény maga nem tud Bluetooth-on rollert vezérelni. Az app
//  indításkor regisztrálja a kezelőt (IntentBridge); a bővítményben kezelő nincs.
//  Biztonság: csak feloldott telefonnal fut (zárolt képernyőn Face ID / kód kell).

import AppIntents

@MainActor
enum IntentBridge {
    /// true = zárás, false = nyitás. Az app (ScooterLinkApp) állítja be.
    static var handler: ((Bool) async throws -> Void)?

    static func run(lock: Bool) async throws {
        // háttérből indított appnál a kezelő a folyamat indulásakor kerül be — rövid türelmi idő
        for _ in 0..<20 where handler == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        guard let handler else { throw ScooterIntentError(message: "Az app nem érhető el.") }
        try await handler(lock)
    }
}

/// Emberi nyelvű hiba (a Parancsok app és a rendszer ezt mutatja).
struct ScooterIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

struct LockScooterIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Roller zárása"
    static var description = IntentDescription("Lezárja a rollert a telefon Bluetooth-án keresztül.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    func perform() async throws -> some IntentResult {
        try await IntentBridge.run(lock: true)
        return .result()
    }
}

struct UnlockScooterIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Roller nyitása"
    static var description = IntentDescription("Kinyitja a rollert a telefon Bluetooth-án keresztül.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    func perform() async throws -> some IntentResult {
        try await IntentBridge.run(lock: false)
        return .result()
    }
}
