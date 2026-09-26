//  ScooterWidgets.swift  — a widget-bővítmény: kezdőképernyő-widget (közepes) és két
//  vezérlő (Vezérlőközpont, zárolt képernyő, Művelet gomb). A gombok intentjei az app
//  folyamatában futnak (Shared/ScooterIntents.swift); az állapotot az app írja (SharedState).

import WidgetKit
import SwiftUI
import AppIntents

@main
struct ScooterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScooterStatusWidget()
        LockControl()
        UnlockControl()
    }
}

// MARK: - Kezdőképernyő-widget

struct StatusEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, state: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, state: context.isPreview ? .sample : SharedState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // Az app minden művelet után újratölti; éjfél után a „ma / tegnap” felirat miatt újrarajzolunk.
        let state = SharedState.load()
        SharedState.log("idővonal [\(context.family), \(Int(context.displaySize.width))×\(Int(context.displaySize.height))]: "
                        + "zárva=\(state.locked.map { "\($0)" } ?? "?"), "
                        + "frissítve=\(state.updated.map { "\($0)" } ?? "?"), hiba=\(state.lastFailure ?? "nincs")")
        let afterMidnight = Calendar.current.startOfDay(for: .now).addingTimeInterval(24 * 3600 + 60)
        completion(Timeline(entries: [StatusEntry(date: .now, state: state)], policy: .after(afterMidnight)))
    }
}

extension WidgetState {
    /// A widget-galéria előnézete.
    static let sample = WidgetState(locked: true, updated: .now)
}

struct ScooterStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScooterStatus", provider: StatusProvider()) { entry in
            StatusEntryView(entry: entry)
                .containerBackground(for: .widget) { ScooterWidgetBackground(locked: entry.state.locked) }
        }
        .configurationDisplayName("Roller")
        .description("Zárás és nyitás egy koppintással.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatusEntryView: View {
    let entry: StatusEntry

    var body: some View { ScooterWidgetView(state: entry.state) }
}

// MARK: - Vezérlők (Vezérlőközpont, zárolt képernyő, Művelet gomb)

struct LockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "hu.scooterlink.lock") {
            ControlWidgetButton(action: LockScooterIntent()) {
                Label("Roller zárása", systemImage: "lock.fill")
            }
        }
        .displayName("Roller zárása")
        .description("Lezárja a rollert.")
    }
}

struct UnlockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "hu.scooterlink.unlock") {
            ControlWidgetButton(action: UnlockScooterIntent()) {
                Label("Roller nyitása", systemImage: "lock.open.fill")
            }
        }
        .displayName("Roller nyitása")
        .description("Kinyitja a rollert.")
    }
}
