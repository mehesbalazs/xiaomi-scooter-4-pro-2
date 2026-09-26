//  SharedState.swift  — az app és a widgetek közös állapota (App Group-tároló).
//  Az app ír bele minden művelet után; a widget ebből rajzol. Fájlban (JSON) tároljuk, nem
//  UserDefaults-ban: így a widget-folyamat mindig a friss állapotot olvassa.

import Foundation

struct WidgetState: Codable, Equatable {
    var locked: Bool?
    var updated: Date?          // mikor volt utoljára ismert a zárállapot
    var lastFailure: String?    // pl. „Zárás sikertelen” — amíg egy újabb siker nem törli
    var lastFailureDate: Date?

    /// A hiba frissebb-e az utolsó ismert állapotnál (csak akkor mutatjuk).
    var showsFailure: Bool {
        guard lastFailure != nil, let f = lastFailureDate else { return false }
        return f >= (updated ?? .distantPast)
    }
}

enum SharedState {
    /// Az App Group azonosítója az Info.plist-ből (a project.yml a BUNDLE_ID_PREFIX-ből képzi).
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "ScooterAppGroup") as? String ?? ""

    /// A közös tároló mappája: az App Group `Library/Application Support` mappája (ez a Macről
    /// `devicectl … --domain-type appGroupDataContainer`-rel is olvasható). App Group nélkül —
    /// pl. szimulátoros demóban — az app saját mappája.
    static var directory: URL {
        if !appGroup.isEmpty,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url.appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var fileURL: URL { directory.appendingPathComponent("widgetState.json") }

    static func load() -> WidgetState {
        guard let d = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(WidgetState.self, from: d) else { return WidgetState() }
        return s
    }

    static func save(_ s: WidgetState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? d.write(to: fileURL, options: .atomic)
    }

    /// Rövid diagnosztikai napló a közös tárolóban (a widget-folyamat ide ír; max. ~64 KB).
    static func log(_ line: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("widget.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp)  \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 64 * 1024, let all = try? Data(contentsOf: url) {
            try? Data(all.suffix(32 * 1024)).write(to: url)
        }
    }
}
