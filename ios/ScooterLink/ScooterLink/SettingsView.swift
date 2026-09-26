//  SettingsView.swift  — PIN, felhőkulcs (mindkettő a Kulcskarikában) és diagnosztika.

import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var vm: ScooterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var key = ""
    @State private var showPin = false
    @State private var showKey = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showPin { TextField("PIN", text: $pin) }
                            else { SecureField("PIN", text: $pin) }
                        }
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.body.monospacedDigit())
                        Button { showPin.toggle() } label: {
                            Image(systemName: showPin ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(showPin ? "PIN elrejtése" : "PIN megjelenítése")
                    }
                } header: {
                    Text("Roller PIN")
                } footer: {
                    Text("Ezzel fejti ki az app a felhőkulcsból a bejelentkezési kulcsot. Csak ezen az eszközön, a Kulcskarikában tárolódik.")
                }

                Section {
                    HStack(alignment: .top) {
                        Group {
                            if showKey {
                                TextField("64 hexadecimális karakter", text: $key, axis: .vertical)
                                    .font(.system(.footnote, design: .monospaced))
                                    .lineLimit(2...4)
                            } else {
                                SecureField("64 hexadecimális karakter", text: $key)
                                    .font(.body)                      // a pontok mérete mint a PIN-nél
                            }
                        }
                        .textContentType(.oneTimeCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(showKey ? "Kulcs elrejtése" : "Kulcs megjelenítése")
                    }
                } header: {
                    Text("Felhőkulcs")
                } footer: {
                    if let problem = ScooterViewModel.keyProblem(key) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if !key.isEmpty {
                        Label("Formailag rendben", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("A titkosított felhőkulcs (SCOOTER_PSK_LOCAL), a tokens/get_ltmk.py kimenete.")
                    }
                }

                Section {
                    if let r = vm.rememberedScooter {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            Text("Megjegyezve: " + stamp(r.since)).foregroundStyle(.secondary)
                            Text(r.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                        Button(role: .destructive) { vm.forgetScooter() } label: {
                            Label("Roller elfelejtése", systemImage: "xmark.circle").foregroundStyle(.red)
                        }
                    } else {
                        Text("Még nincs megjegyezve").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Rögzített roller")
                } footer: {
                    Text("Az első sikeres művelet után az app megjegyzi a rollered, és utána csak ahhoz csatlakozik — több ugyanilyen roller közelében is. Másik rollerhez felejtsd el: a következő művelet (az appból) újra keres.")
                }

                if !readableLog.isEmpty {
                    Section {
                        Text(readableLog.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = readableLog.joined(separator: "\n")
                        } label: {
                            Label("Napló másolása", systemImage: "doc.on.doc")
                        }
                    } header: {
                        Text("Utolsó művelet naplója")
                    }
                }

                Section("Névjegy") {
                    aboutRow("Roller", "\(ScooterModel.family) \(ScooterModel.variant)")
                    aboutRow("Modell", ScooterModel.modelId)
                    aboutRow("App-verzió", appVersion)
                }
            }
            .navigationTitle("Beállítások")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Mégse") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mentés") {
                        vm.saveCredentials(pin: pin, key: key)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded else { return }
                pin = vm.pin; key = vm.cloudKey; loaded = true
            }
        }
    }

    /// A napló olvasható része: a nyers BLE-keretek és a kihagyott eszközök nélkül
    /// (a teljes napló a Documents/scooterlink.log-ban marad).
    private var readableLog: [String] {
        vm.log.filter { !$0.hasPrefix("<-") && !$0.hasPrefix("⇠") && !$0.hasPrefix("kihagyva") }
    }

    /// Névjegy-sor: felül a cím, alatta szürkén az érték (minden sorban egységesen).
    private func aboutRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
