//  FrameQueue.swift  — aszinkron, sorrendtartó keret-sor időtúllépéssel.
//  A BLE-callbackek (főszál) put()-olnak, a login/SPEC-folyamat next()-tel vár.

import Foundation

final class FrameQueue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [T] = []
    private var waiter: (id: UInt64, fn: (T?) -> Void)?
    private var nextId: UInt64 = 0
    private var closed = false

    func put(_ item: T) {
        lock.lock()
        if closed { lock.unlock(); return }
        if let w = waiter { waiter = nil; lock.unlock(); w.fn(item) }
        else { buffer.append(item); lock.unlock() }
    }

    /// A pufferelt (korábbi kérésből maradt) keretek eldobása.
    func drain() { lock.lock(); buffer.removeAll(); lock.unlock() }

    /// A kapcsolat megszakadt: a várakozó azonnal nil-t kap, a további next() is,
    /// amíg reopen() nem jön — így egy halott linken nem várunk végig minden időtúllépést.
    func close() {
        lock.lock(); closed = true; buffer.removeAll()
        let w = waiter; waiter = nil
        lock.unlock()
        w?.fn(nil)
    }

    /// Új session: üres, nyitott sor.
    func reopen() { lock.lock(); closed = false; buffer.removeAll(); lock.unlock() }

    /// Mint next(timeout:), de a `skip`-re illeszkedő kereteket eldobja — a teljes időkereten belül.
    func next(timeout: TimeInterval, skipping skip: (T) -> Bool) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let item = await next(timeout: left) else { return nil }
            if !skip(item) { return item }
        }
    }

    func next(timeout: TimeInterval) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = NSLock(); var done = false
            let finish: (T?) -> Void = { v in
                once.lock(); if done { once.unlock(); return }; done = true; once.unlock()
                cont.resume(returning: v)
            }
            // A puffer-ellenőrzés és a várakozó beállítása egy zár alatt: így egy közben
            // érkező keret nem ragadhat a pufferben, amíg mi a várakozón időtúllépésig ülünk.
            lock.lock()
            if !buffer.isEmpty { let it = buffer.removeFirst(); lock.unlock(); finish(it); return }
            if closed { lock.unlock(); finish(nil); return }
            nextId &+= 1
            let id = nextId
            waiter = (id, finish)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Csak a SAJÁT várakozónkat töröljük: egy már teljesült hívás késői időzítője
                // nem ütheti ki a következő next() várakozóját (különben annak kerete elveszne).
                self.lock.lock()
                if self.waiter?.id == id { self.waiter = nil }
                self.lock.unlock()
                finish(nil)
            }
        }
    }
}
