//  Formatting.swift  — közös formázás és színek (app + widget), magyar területi beállítással.

import SwiftUI

/// A zárállapot színe: zárva zöld, nyitva narancs, ismeretlen szürke.
func lockTint(_ locked: Bool?) -> Color {
    switch locked {
    case true?: return .green
    case false?: return .orange
    case nil: return .gray
    }
}

let hu = Locale(identifier: "hu_HU")

func num(_ v: Double, _ digits: Int) -> String {
    v.formatted(.number.precision(.fractionLength(digits)).locale(hu))
}

func km(_ v: Double) -> String { num(v, 1) + " km" }

/// 0 → „0 perc”; 45 → „45 mp”; 740 → „12 perc”; 3900 → „1 ó 5 p”
func duration(_ s: Double) -> String {
    if s < 1 { return "0 perc" }
    if s < 60 { return "\(Int(s)) mp" }
    let m = Int(s / 60)
    return m < 60 ? "\(m) perc" : "\(m / 60) ó \(m % 60) p"
}

/// „épp most” / „12 perccel ezelőtt”; 6 óránál régebbire az abszolút idő (stamp).
func relative(_ d: Date, now: Date = .now) -> String {
    let s = now.timeIntervalSince(d)
    if s < 60 { return "épp most" }
    if s > 6 * 3600 { return stamp(d) }
    let f = RelativeDateTimeFormatter()
    f.locale = hu; f.unitsStyle = .full
    return f.localizedString(for: d, relativeTo: now)
}

/// „ma 14:32” / „tegnap 09:05” / „szept. 21. 18:40”
func stamp(_ d: Date) -> String {
    let time = d.formatted(Date.FormatStyle(locale: hu).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "ma \(time)" }
    if cal.isDateInYesterday(d) { return "tegnap \(time)" }
    return d.formatted(Date.FormatStyle(locale: hu).month(.abbreviated).day()) + " " + time
}
