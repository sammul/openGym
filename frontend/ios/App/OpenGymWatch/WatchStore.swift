import Foundation
import WatchKit
import UserNotifications

/**
 * Everything the watch app knows and does. Two ways a session runs here:
 *  - live: the workout running on the iPhone. The phone's snapshot is the truth; each change made
 *    here goes to the phone as a command and is shown at once on top of the last snapshot, until a
 *    snapshot arrives that says it was applied (`seen`).
 *  - solo: a session started here from the pack. It runs entirely on the watch, saved after every
 *    change, and goes to the phone whole at Finish, whenever the phone is next in reach.
 * The order of the sets and the rest after each come from the phone (lib/watch.js); nothing here
 * decides a weight.
 */
@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var pack: Pack?
    @Published private(set) var live: LiveActive?
    @Published private(set) var solo: SoloSession?
    @Published private(set) var rest: Rest?
    @Published var focus: Int?
    @Published private(set) var reachable = false
    @Published var notice: String?

    private var liveBase: LiveActive?
    private var liveAt: Double = 0
    private var pending: [(id: String, patch: SetPatch)] = []
    private var pendingRest: String?
    private var finishedSids: Set<String> = []
    private var restTimer: Timer?

    private static let restNotificationId = "opengym.rest"

    init() {
        pack = Self.load(Pack.self, from: "pack.json")
        solo = Self.load(SoloSession.self, from: "solo.json")
        rest = solo?.rest
        let c = Connectivity.shared
        c.onPack = { [weak self] text in self?.receivePack(text) }
        c.onLive = { [weak self] text in self?.receiveLive(text) }
        c.onReachable = { [weak self] r in
            self?.reachable = r
            // Back in reach: ask for what may have changed meanwhile.
            if r { c.send(["type": "hello"]) }
        }
        c.activate()
        armRest()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: what is running

    var running: Bool { solo != nil || live != nil }
    var isSolo: Bool { solo != nil }
    var name: String { solo?.name ?? live?.name ?? "" }
    var entries: [EntryView] { solo?.entries ?? live?.entries ?? [] }
    var order: [OrderStep] { solo?.order ?? live?.order ?? [] }
    var unit: String { solo?.unit ?? live?.unit ?? pack?.unit ?? "kg" }

    func isDone(_ step: OrderStep) -> Bool {
        guard step.e < entries.count, step.i < entries[step.e].sets.count else { return true }
        return entries[step.e].sets[step.i].done
    }

    /// The step on screen: the one picked from the list, else the first not done yet.
    var current: Int? {
        if let f = focus, f < order.count { return f }
        return order.firstIndex { !isDone($0) }
    }

    func label(_ key: String, _ fallback: String) -> String { pack?.labels?[key] ?? fallback }

    // MARK: sessions

    func start(_ s: PackSession) {
        guard !running else { return }
        let now = Clock.nowMs()
        solo = SoloSession(sid: UUID().uuidString, start: now, name: s.name, rids: s.rids, unit: s.unit, raw: s.raw,
                           entries: s.entries, order: s.order, patches: [], rest: nil)
        focus = nil
        saveSolo()
        WorkoutManager.shared.start()
    }

    func finish() {
        let now = Clock.nowMs()
        if let s = solo {
            var cmd: [String: Any] = ["id": UUID().uuidString, "type": "session", "sid": s.sid, "start": s.start, "end": now,
                                      "name": s.name, "rids": s.rids, "raw": s.raw]
            cmd["patches"] = s.patches.compactMap(Self.dict)
            Connectivity.shared.sendFile(cmd)
            solo = nil
            saveSolo()
            notice = label("saved", "Saved. It goes to your iPhone when it is in range.")
        } else if let l = live {
            Connectivity.shared.send(["id": UUID().uuidString, "type": "finish", "sid": l.sid])
            finishedSids.insert(l.sid)
            live = nil
            liveBase = nil
            pending = []
        }
        stopRest(tell: false)
        focus = nil
        WorkoutManager.shared.end(save: true)
    }

    func discard() {
        guard solo != nil else { return }
        solo = nil
        saveSolo()
        stopRest(tell: false)
        focus = nil
        WorkoutManager.shared.end(save: false)
    }

    // MARK: sets

    /// Ticks the step with the values on screen, rests what the phone said to rest after it, and
    /// moves on.
    func complete(_ index: Int, w: Double?, r: Double?, sec: Double?, min: Double?) {
        guard index < order.count else { return }
        let step = order[index]
        let entry = entries[step.e]
        let row = entry.sets[step.i]
        var patch = SetPatch(e: step.e, x: entry.id, i: step.i, w: w, r: r, sec: sec, min: min, done: true, sides: nil, at: Clock.nowMs())
        if row.isPerSide, let r = r {
            // Reps shown per side; the weight goes to both.
            patch.r = nil
            patch.sides = ["L": .init(r: r), "R": .init(r: r)]
        }
        apply(patch)
        focus = nil
        WKInterfaceDevice.current().play(.success)
        if current == nil { stopRest(tell: true); return }
        if step.rest > 0 { startRest(step.rest) }
    }

    func undo(_ index: Int) {
        guard index < order.count else { return }
        let step = order[index]
        apply(SetPatch(e: step.e, x: entries[step.e].id, i: step.i, done: false, at: Clock.nowMs()))
    }

    private func apply(_ patch: SetPatch) {
        if var s = solo {
            s.entries = s.entries.applying(patch)
            s.patches.append(patch)
            solo = s
            saveSolo()
        } else if var l = live {
            let id = UUID().uuidString
            if var cmd = Self.dict(patch) {
                cmd["id"] = id; cmd["type"] = "set"; cmd["sid"] = l.sid
                Connectivity.shared.send(cmd)
            }
            pending.append((id, patch))
            l.entries = l.entries.applying(patch)
            live = l
        }
    }

    // MARK: rest

    func startRest(_ sec: Double) {
        let now = Clock.nowMs()
        rest = Rest(endsAt: now + sec * 1000, total: sec)
        tellRest(["op": "start", "sec": sec, "at": now])
        persistRest()
        armRest()
    }

    func addRest(_ sec: Double) {
        guard var r = rest else { return }
        r.endsAt += sec * 1000
        r.total = max(r.total + sec, 1)
        rest = r.endsAt > Clock.nowMs() ? r : nil
        tellRest(["op": "add", "sec": sec])
        persistRest()
        armRest()
    }

    func skipRest() { stopRest(tell: true) }

    private func stopRest(tell: Bool) {
        let had = rest != nil
        rest = nil
        if tell && had { tellRest(["op": "skip"]) }
        persistRest()
        armRest()
    }

    private func tellRest(_ fields: [String: Any]) {
        guard let l = live else { return }
        let id = UUID().uuidString
        var cmd = fields
        cmd["id"] = id; cmd["type"] = "rest"; cmd["sid"] = l.sid
        Connectivity.shared.send(cmd)
        pendingRest = id
    }

    private func persistRest() {
        guard var s = solo else { return }
        s.rest = rest
        solo = s
        saveSolo()
    }

    /// The buzz at the end of the rest: a timer while the app runs (the Health workout keeps it
    /// running with the wrist down), and a notification in case it does not.
    private func armRest() {
        restTimer?.invalidate()
        restTimer = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotificationId])
        guard let r = rest, r.paused != true else { return }
        let wait = (r.endsAt - Clock.nowMs()) / 1000
        guard wait > 0 else { rest = nil; return }
        restTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restOver() }
        }
        let content = UNMutableNotificationContent()
        content.title = label("restOver", "Rest’s over. Next set!")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.restNotificationId, content: content, trigger: trigger))
    }

    private func restOver() {
        guard let r = rest, r.paused != true, r.endsAt <= Clock.nowMs() + 500 else { return }
        WKInterfaceDevice.current().play(.notification)
        rest = nil
        persistRest()
        // Rang here already: the notification would only ring again.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.restNotificationId])
    }

    // MARK: from the phone

    private func receivePack(_ text: String) {
        guard let data = text.data(using: .utf8), let p = try? JSONDecoder().decode(Pack.self, from: data) else { return }
        if let old = pack, old.built > p.built { return }
        pack = p
        Self.save(data, to: "pack.json")
    }

    private func receiveLive(_ text: String) {
        guard let data = text.data(using: .utf8), let snap = try? JSONDecoder().decode(LiveSnapshot.self, from: data) else { return }
        guard snap.at >= liveAt else { return }
        liveAt = snap.at
        let seen = Set(snap.seen ?? [])
        pending.removeAll { seen.contains($0.id) }
        guard let a = snap.active, !finishedSids.contains(a.sid) else {
            if live != nil {
                // Finished or discarded on the phone.
                live = nil
                liveBase = nil
                pending = []
                if solo == nil { stopRest(tell: false); WorkoutManager.shared.end(save: true) }
            }
            return
        }
        if liveBase?.sid != a.sid { focus = nil; pending = [] }
        liveBase = a
        var shown = a
        for p in pending { shown.entries = shown.entries.applying(p.patch) }
        live = shown
        // The phone's rest, unless this watch changed it a moment ago and the phone has not heard yet.
        if solo == nil && (pendingRest == nil || seen.contains(pendingRest!)) {
            pendingRest = nil
            if rest != a.rest { rest = a.rest; armRest() }
        }
    }

    // MARK: storage

    private func saveSolo() {
        if let s = solo, let data = try? JSONEncoder().encode(s) { Self.save(data, to: "solo.json") }
        else { try? FileManager.default.removeItem(at: Self.url("solo.json")) }
    }

    private static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private static func save(_ data: Data, to name: String) { try? data.write(to: url(name), options: .atomic) }

    private static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func dict(_ patch: SetPatch) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(patch) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
