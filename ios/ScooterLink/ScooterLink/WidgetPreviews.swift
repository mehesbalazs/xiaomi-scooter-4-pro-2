//  WidgetPreviews.swift  — Debug: a widget-nézetek képe (`-renderWidgets`, szimulátoros ellenőrzéshez).

#if DEBUG
import SwiftUI
import WidgetKit

@MainActor
enum WidgetPreviews {
    /// A (közepes) widget világos és sötét módban, négy állapotban → Documents/widget-*.png
    static func render() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let now = Date()
        let states: [(String, WidgetState)] = [
            ("zarva", WidgetState(locked: true, updated: now.addingTimeInterval(-600))),
            ("nyitva", WidgetState(locked: false, updated: now)),
            ("hiba", WidgetState(locked: true, updated: now.addingTimeInterval(-3600),
                                 lastFailure: "Nyitás sikertelen", lastFailureDate: now)),
            ("ures", WidgetState()),
        ]
        let size = CGSize(width: 364, height: 170)       // közepes widget (6,7"-es iPhone)
        for (name, state) in states {
            for (scheme, schemeName) in [(ColorScheme.light, "vilagos"), (.dark, "sotet")] {
                let view = ScooterWidgetView(state: state)
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(ScooterWidgetBackground(locked: state.locked))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                if let png = renderer.uiImage?.pngData() {
                    try? png.write(to: docs.appendingPathComponent("widget-\(name)-\(schemeName).png"))
                }
            }
        }
        trace("[DEBUG] widget-előnézetek: \(docs.path)")
    }
}
#endif
