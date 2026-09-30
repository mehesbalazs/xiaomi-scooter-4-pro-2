//  ContentView.swift  — a roller-vezérlő fő képernyője.

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ScooterViewModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            // Nincs ScrollView: a képernyő sosem görgethető. A zárkör a maradék helyet
            // tölti ki, és zsugorodik, ha pl. hibasáv vagy beállítás-kártya is látszik.
            VStack(spacing: 14) {
                if !vm.hasCredentials {
                    SetupCard { showSettings = true }
                }
                LockHero(locked: vm.locked, updated: vm.lockUpdated, busy: vm.busy, step: vm.step,
                         pulse: vm.successCount)
                    .frame(maxHeight: .infinity)
                lockButtons
                if let msg = vm.errorMessage {
                    ErrorBanner(message: msg) { vm.errorMessage = nil }
                }
                TelemetryCard(telemetry: vm.telemetry,
                              tint: lockTint(vm.locked),
                              refreshing: vm.running == .refresh,
                              disabled: vm.busy || !vm.hasCredentials) {
                    Task { await vm.run(.refresh) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.snappy, value: vm.errorMessage)
            .background { Backdrop(tint: lockTint(vm.locked)) }
            .navigationTitle("\(ScooterModel.family) \(ScooterModel.variant)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(ScooterModel.family).font(.caption).foregroundStyle(.secondary)
                        Text(ScooterModel.variant).font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Beállítások")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)   // fix elrendezés: a szövegméret felső korlátja
        .sensoryFeedback(.success, trigger: vm.successCount)
        .sensoryFeedback(.error, trigger: vm.failureCount)
        .environment(\.locale, hu)
        #if DEBUG
        .task {
            await vm.runSelfTestIfRequested(); await vm.runBenchIfRequested(); await vm.runIntentTestIfRequested()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.syncFromShared() }      // közben widgetről zárhattak / nyithattak
        }
    }

    private var lockButtons: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Zárás", icon: "lock.fill", tint: .green,
                         emphasized: vm.locked != true, running: vm.running == .lock) {
                Task { await vm.run(.lock) }
            }
            ActionButton(title: "Nyitás", icon: "lock.open.fill", tint: .orange,
                         emphasized: vm.locked != false, running: vm.running == .unlock) {
                Task { await vm.run(.unlock) }
            }
        }
        .disabled(vm.busy || !vm.hasCredentials)
    }
}

// MARK: - Zárállapot


struct LockHero: View {
    let locked: Bool?
    let updated: Date?
    let busy: Bool
    let step: String
    let pulse: Int            // sikeres műveletenként nő → a lakat „megugrik”

    var body: some View {
        let tint = lockTint(locked)
        GeometryReader { geo in
            if geo.size.height >= 150 {
                // a kör átmérője a rendelkezésre álló magasságból (a felirat ~84 pt)
                let d = min(150, geo.size.height - 84)
                let ring = d * 0.075
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.gradient.opacity(0.16))
                        Circle().strokeBorder(tint.opacity(0.22), lineWidth: ring)
                        if busy { SpinnerArc(tint: tint, lineWidth: ring) }
                        Image(systemName: icon)
                            .font(.system(size: d * 0.36, weight: .semibold))
                            .foregroundStyle(tint)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: pulse)
                    }
                    .frame(width: d, height: d)
                    .shadow(color: tint.opacity(0.3), radius: d * 0.13, y: d * 0.05)
                    labels
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                // szűk hely (pl. nagy betűméret + hibasáv): kör helyett kompakt sor
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(tint) }
                        else {
                            Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(tint)
                                .symbolEffect(.bounce, value: pulse)
                        }
                        Text(title).font(.title2.weight(.bold))
                    }
                    subtitleView
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .animation(.smooth, value: locked)
        .animation(.smooth, value: step)
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            subtitleView
        }
    }

    private var subtitleView: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(subtitle(now: ctx.date))
                .font(.subheadline).foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
    }

    private var icon: String {
        switch locked {
        case true?: return "lock.fill"
        case false?: return "lock.open.fill"
        case nil: return "questionmark"
        }
    }
    private var title: String {
        switch locked {
        case true?: return "Zárva"
        case false?: return "Nyitva"
        case nil: return "Ismeretlen állapot"
        }
    }
    private func subtitle(now: Date) -> String {
        if busy { return step.isEmpty ? "Dolgozom…" : step }
        if let u = updated { return "Frissítve: " + relative(u, now: now) }
        return "Még nincs adat — frissítsd lent"
    }
}

/// Forgó ív a gyűrűn, amíg egy művelet fut.
struct SpinnerArc: View {
    let tint: Color
    let lineWidth: CGFloat
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .padding(lineWidth / 2)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let emphasized: Bool      // a „logikus következő lépés” telített, a másik halvány
    let running: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if running { ProgressView().tint(emphasized ? .white : tint) }
                else { Image(systemName: icon) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(emphasized ? Color.white : tint)
            .background(emphasized ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.15)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isEnabled || running ? 1 : 0.45)
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Kártyák

struct SetupCard: View {
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Beállítás szükséges", systemImage: "key.fill").font(.headline)
            Text("Add meg a roller PIN-kódját és a felhőkulcsot, utána egy gombnyomás a zárás és a nyitás.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Beállítások megnyitása", action: open)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bezárás")
        }
        .padding(14)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct TelemetryCard: View {
    let telemetry: Telemetry?
    let tint: Color                  // a zárállapot színe (sötét módban ezzel árnyalt a kártya)
    let refreshing: Bool
    let disabled: Bool
    let refresh: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // középre igazított fejléc (mint a lenti oszlopok), a frissítés kerek gombként a sarokban
            ZStack {
                VStack(spacing: 2) {
                    Text("Roller adatai").font(.title3.weight(.semibold))
                    Text(telemetry.map { "Frissítve: " + stamp($0.updated) } ?? "Még nem olvastad ki")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Spacer()
                    Button(action: refresh) {
                        ZStack {
                            if refreshing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)) }
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(disabled)
                    .opacity(disabled && !refreshing ? 0.5 : 1)
                    .accessibilityLabel(refreshing ? "Olvasás folyamatban" : "Frissítés")
                }
            }

            if let t = telemetry {
                BatteryGauge(level: t.battery, rangeKm: t.rangeKm)
                // párok: távolság · akku-egészség · elektromos/hő; egy sorban azonos magasság
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        StatTile(icon: "scooter", tint: .indigo, title: "Aktuális út",
                                 pairs: [("Táv", t.tripKm.map { km($0) }), ("Idő", t.tripSeconds.map(duration))])
                        StatTile(icon: "gauge.with.needle", tint: .blue, title: "Össz-km",
                                 value: t.totalKm.map { km($0) })
                    }
                    GridRow {
                        StatTile(icon: "heart.fill", tint: .pink, title: "Akku-állapot",
                                 value: t.soh.map { "\($0)%" })
                        StatTile(icon: "arrow.triangle.2.circlepath", tint: .teal, title: "Töltési ciklus",
                                 value: t.cycles.map { "\($0)" })
                    }
                    GridRow {
                        StatTile(icon: "bolt.fill", tint: .orange, title: "Feszültség",
                                 value: t.voltage.map { num($0, 1) + " V" })
                        StatTile(icon: "thermometer.medium", tint: .red, title: "Hőmérséklet",
                                 pairs: [("Akku", t.batteryTemperature.map { "\($0) °C" }),
                                         ("Roller", t.temperature.map { "\($0) °C" })])
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Koppints a \(Image(systemName: "arrow.clockwise")) gombra az akku, a hatótáv és a többi adat kiolvasásához.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding(18)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            if scheme == .dark {     // sötétben finom, színezett perem a kártya körvonalához
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1)
            }
        }
        .animation(.smooth(duration: 0.6), value: tint)
    }

    /// Világosban a szokásos fehér kártya; sötétben a szürke helyett a zárállapot színével
    /// árnyalt, mély felület (illik a felső fényhez és a gombokhoz).
    private var cardFill: AnyShapeStyle {
        scheme == .dark ? AnyShapeStyle(tint.opacity(0.10)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }
}

struct BatteryGauge: View {
    let level: Int?
    let rangeKm: Double?

    var body: some View {
        let lv = min(max(level ?? 0, 0), 100)
        let color: Color = lv >= 50 ? .green : (lv >= 20 ? .yellow : .red)
        VStack(alignment: .leading, spacing: 12) {
            // két egyforma oszlop, köztük vékony elválasztó: az akku és a hatótáv azonos súllyal
            HStack(spacing: 0) {
                metric(icon: batteryIcon(lv), tint: color, title: "Akkumulátor",
                       value: level.map(String.init) ?? "—", unit: "%", alignment: .center)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 44)
                metric(icon: "signpost.right.fill", tint: .blue, title: "Becsült hatótáv",
                       value: rangeKm.map { num($0, 1) } ?? "—", unit: "km", alignment: .center)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.gradient)
                        .frame(width: max(10, g.size.width * CGFloat(lv) / 100))
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .combine)
    }

    /// Címke + nagy, kerekített szám szürke mértékegységgel (az akku és a hatótáv azonos stílusban).
    private func metric(icon: String, tint: Color, title: String, value: String, unit: String,
                        alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private func batteryIcon(_ lv: Int) -> String {
        switch lv {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    /// Egy érték (felirat nélkül), vagy több érték egymás mellett, kis felirattal.
    let values: [(label: String?, value: String?)]

    @Environment(\.colorScheme) private var scheme

    init(icon: String, tint: Color, title: String, value: String?) {
        self.icon = icon; self.tint = tint; self.title = title; values = [(nil, value)]
    }
    init(icon: String, tint: Color, title: String, pairs: [(String, String?)]) {
        self.icon = icon; self.tint = tint; self.title = title; values = pairs.map { ($0.0, $0.1) }
    }

    var body: some View {
        // minden középre igazítva; az értékek alul, így egy sorban a szimpla és a páros
        // csempe alapvonala egyezik
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint).fontWeight(.semibold)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            Spacer(minLength: 8)
            // az értékek a csempe alján; a szimpla csempékben is fenntartjuk a kis felirat
            // helyét (láthatatlanul), így minden csempe egyforma magas, és az értékek a sorok
            // között is azonos magasságban ülnek (pl. „135” a „51,7 V”-tal egy vonalban)
            HStack(alignment: .lastTextBaseline, spacing: 20) {
                ForEach(values.indices, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text(values[i].label ?? " ")
                            .font(.caption2).foregroundStyle(.secondary)
                            .opacity(values[i].label == nil ? 0 : 1)
                        Text(values[i].value ?? "—")
                            .font(.headline).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(scheme == .dark ? AnyShapeStyle(Color.white.opacity(0.06))
                                    : AnyShapeStyle(Color(.tertiarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Háttér: csoportos rendszerháttér + a zárállapot színében derengő fény felül.
struct Backdrop: View {
    let tint: Color
    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 420)
                .frame(height: 520)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: tint)
    }
}

#Preview { ContentView() }
