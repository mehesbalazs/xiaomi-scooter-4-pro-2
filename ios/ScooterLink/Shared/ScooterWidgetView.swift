//  ScooterWidgetView.swift  — a kezdőképernyő-widget nézete (közepes méret): balra a zárállapot
//  az időponttal, jobbra két nagy gomb (Zárás, Nyitás). Az app is lefordítja (Debug-előnézethez),
//  a gombok App Intentet indítanak.

import SwiftUI
import WidgetKit
import AppIntents

struct ScooterWidgetView: View {
    let state: WidgetState

    var body: some View {
        HStack(spacing: 10) {
            // balra az állapot: lakat a felirat fölött, mindkét irányban középen
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title.weight(.semibold)).foregroundStyle(tint)
                Text(title).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                detail.font(.caption).lineLimit(1).minimumScaleFactor(0.7)
            }
            .multilineTextAlignment(.center)
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .invalidatableContent()          // koppintás után, amíg a művelet fut, halványítva
            actionButton(lock: true)
            actionButton(lock: false)
        }
        .environment(\.locale, hu)
    }

    private var tint: Color { lockTint(state.locked) }

    private var icon: String {
        switch state.locked {
        case true?: return "lock.fill"
        case false?: return "lock.open.fill"
        case nil: return "questionmark"
        }
    }

    private var title: String {
        switch state.locked {
        case true?: return "Zárva"
        case false?: return "Nyitva"
        case nil: return "Ismeretlen"
        }
    }

    /// „ma 14:32”, vagy ha az utolsó művelet elbukott, a hiba.
    @ViewBuilder private var detail: some View {
        if state.showsFailure, let f = state.lastFailure {
            Label(f, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if let u = state.updated {
            Text(stamp(u)).foregroundStyle(.secondary)
        } else {
            Text("Még nincs adat").foregroundStyle(.secondary)
        }
    }

    // MARK: Gombok

    /// Nagy gomb: ikon + felirat. A „logikus következő lépés” telített, a másik halvány (mint az appban).
    @ViewBuilder
    private func actionButton(lock: Bool) -> some View {
        let color: Color = lock ? .green : .orange
        let emphasized = lock ? state.locked != true : state.locked != false
        let label = VStack(spacing: 4) {
            Image(systemName: lock ? "lock.fill" : "lock.open.fill").font(.title.weight(.semibold))
            Text(lock ? "Zárás" : "Nyitás").font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(emphasized ? Color.white : color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(emphasized ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.18)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        Group {
            if lock { Button(intent: LockScooterIntent()) { label } }
            else { Button(intent: UnlockScooterIntent()) { label } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lock ? "Roller zárása" : "Roller nyitása")
    }
}

/// A widget háttere: a zárállapot színében derengő átmenet (mint az app háttere).
struct ScooterWidgetBackground: View {
    let locked: Bool?
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [lockTint(locked).opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
        }
    }
}
