//  ScooterLinkApp.swift  — az app belépési pontja.

import SwiftUI

@main
struct ScooterLinkApp: App {
    init() {
        // A widget-gombok és vezérlők intentjei ezen át futnak (ebben a folyamatban,
        // szükség esetén a háttérben indított appban) — lásd Shared/ScooterIntents.swift.
        IntentBridge.handler = { lock in
            do {
                _ = try await ScooterService.shared.perform(lock ? .lock : .unlock, source: "WIDGET")
            } catch {
                throw ScooterIntentError(message: ScooterViewModel.message(for: error))
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
