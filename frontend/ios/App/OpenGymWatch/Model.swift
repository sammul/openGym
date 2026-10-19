import Foundation

// What the phone sends (lib/watch.js). Everything the watch shows is decided there; these types
// only read it. Fields a newer phone adds are ignored, and anything missing has a default.

struct SideView: Codable, Hashable {
    var w: Double = 0
    var r: Double = 0
    var done: Bool = false
}

struct SetView: Codable, Hashable {
    var done: Bool = false
    var w: Double?
    var r: Double?
    var sec: Double?
    var min: Double?
    var warm: Bool?
    var side: String?
    var sides: [String: SideView]?
    var type: String?

    var isWarmup: Bool { warm == true }
    var isPerSide: Bool { sides != nil }
}

struct EntryView: Codable, Hashable {
    var idx: Int
    var id: String
    var name: String
    var mode: String          // "reps" | "time" | "cardio"
    var step: Double
    var sg: String?
    var sets: [SetView]
}

struct OrderStep: Codable, Hashable {
    var e: Int
    var i: Int
    var rest: Double
}

struct PackSession: Codable, Hashable, Identifiable {
    var key: String
    var rids: [String]
    var name: String
    var today: Bool?
    var unit: String
    var entries: [EntryView]
    var order: [OrderStep]
    var raw: String
    var id: String { key }
}

struct Pack: Codable {
    var v: Int
    var built: Double
    var unit: String
    var labels: [String: String]?
    var sessions: [PackSession]
}

struct Rest: Codable, Hashable {
    var endsAt: Double            // ms since 1970
    var total: Double
    var paused: Bool?
    var left: Double?
    var kind: String?
}

struct LiveActive: Codable, Hashable {
    var sid: String
    var name: String
    var start: Double
    var cur: Int
    var unit: String
    var entries: [EntryView]
    var order: [OrderStep]
    var rest: Rest?
}

struct LiveSnapshot: Codable {
    var v: Int
    var at: Double
    var active: LiveActive?
    var seen: [String]?
}

/// A change to one row, as lib/watch.js applySetPatch reads it.
struct SetPatch: Codable, Hashable {
    var e: Int
    var x: String
    var i: Int
    var w: Double?
    var r: Double?
    var sec: Double?
    var min: Double?
    var done: Bool?
    var sides: [String: SideReps]?
    var at: Double

    struct SideReps: Codable, Hashable { var r: Double }
}

/// A session the watch is running on its own, saved after every change so a crash or a flat
/// battery loses nothing. Handed to the phone whole at Finish (lib/watch.js prepareWatchSession).
struct SoloSession: Codable {
    var sid: String
    var start: Double
    var name: String
    var rids: [String]
    var unit: String
    var raw: String
    var entries: [EntryView]
    var order: [OrderStep]
    var patches: [SetPatch]
    var rest: Rest?
}

enum Clock {
    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

extension SetView {
    /// The row with a patch applied, the way the phone will apply it.
    func applying(_ p: SetPatch) -> SetView {
        var out = self
        if var s = out.sides {
            for key in ["L", "R"] {
                var side = s[key] ?? SideView()
                if let w = p.w { side.w = w }
                if let r = p.r { side.r = r }
                if let own = p.sides?[key] { side.r = own.r }
                if let d = p.done { side.done = d }
                s[key] = side
            }
            out.sides = s
            out.done = (s["L"]?.done ?? false) && (s["R"]?.done ?? false)
            out.w = max(s["L"]?.w ?? 0, s["R"]?.w ?? 0)
            out.r = (s["L"]?.r ?? 0) + (s["R"]?.r ?? 0)
            return out
        }
        if let w = p.w { out.w = w }
        if let r = p.r { out.r = r }
        if let sec = p.sec { out.sec = sec }
        if let m = p.min { out.min = m }
        if let d = p.done { out.done = d }
        return out
    }
}

extension Array where Element == EntryView {
    func applying(_ p: SetPatch) -> [EntryView] {
        var list = self
        var e = p.e
        if e < 0 || e >= list.count || list[e].id != p.x {
            guard let found = list.firstIndex(where: { $0.id == p.x }) else { return list }
            e = found
        }
        guard p.i >= 0, p.i < list[e].sets.count else { return list }
        list[e].sets[p.i] = list[e].sets[p.i].applying(p)
        return list
    }
}
