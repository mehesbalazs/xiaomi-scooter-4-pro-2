//  AppLog.swift  — tartós, időbélyeges napló az app Documents-mappájában.
//  A Macről lehúzható (lásd README-ios.md: „Napló lehúzása”); PIN-t és kulcsot nem tartalmaz.

import Foundation

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    let url: URL
    private let queue = DispatchQueue(label: "hu.scooterlink.applog")
    private let maxBytes = 512 * 1024          // e fölött a régebbi fele eldobódik
    private let stamp: DateFormatter

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("scooterlink.log")
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func write(_ line: String) {
        let now = Date()
        queue.async {
            let data = Data("\(self.stamp.string(from: now))  \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: self.url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: self.url)
            }
            self.trimIfNeeded()
        }
    }

    private func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes, let all = try? Data(contentsOf: url) else { return }
        var keep = all.suffix(maxBytes / 2)
        if let nl = keep.firstIndex(of: 0x0A) { keep = keep[(nl + 1)...] }   // egész sortól kezdjük
        try? Data(keep).write(to: url)
    }
}

/// Konzolra és a tartós naplóba is.
func trace(_ s: String) {
    print(s)
    AppLog.shared.write(s)
}
