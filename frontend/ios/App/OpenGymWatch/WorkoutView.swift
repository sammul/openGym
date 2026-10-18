import SwiftUI

/// A session running, from the phone or on its own: the rest when one is counting, else the set
/// that is next. Swipe to the list of every set, or to Finish.
struct WorkoutView: View {
    @EnvironmentObject var store: WatchStore
    @ObservedObject private var health = WorkoutManager.shared
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            ControlsView().tag(0)
            Group {
                if let rest = store.rest {
                    RestView(rest: rest)
                } else if let idx = store.current {
                    SetScreen(index: idx).id(idx)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                        Text(store.label("allDone", "All sets done")).font(.headline)
                        Button(store.label("finish", "Finish")) { store.finish() }.tint(.green)
                    }
                }
            }.tag(1)
            SetListView().tag(2)
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle(store.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let hr = health.heartRate {
                ToolbarItem(placement: .topBarTrailing) {
                    Label("\(Int(hr))", systemImage: "heart.fill").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        // A workout from the phone gets the Health session too once it is on the wrist.
        .onAppear { if !store.isSolo { WorkoutManager.shared.start() } }
    }
}

/// One set: what to lift, the Digital Crown on whichever value is selected, and Done.
struct SetScreen: View {
    @EnvironmentObject var store: WatchStore
    let index: Int

    @State private var w: Double = 0
    @State private var r: Double = 0
    @State private var sec: Double = 0
    @State private var min: Double = 0
    @State private var editing: Field = .reps
    @FocusState private var crown: Bool

    enum Field { case weight, reps, sec, min }

    private var step: OrderStep { store.order[index] }
    private var entry: EntryView { store.entries[step.e] }
    private var row: SetView { entry.sets[step.i] }

    var body: some View {
        VStack(spacing: 6) {
            Text(entry.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                switch entry.mode {
                case "time":
                    value(.sec, text: "\(Int(sec)) s")
                    if w > 0 { value(.weight, text: weightText) }
                case "cardio":
                    value(.min, text: "\(Int(min)) min")
                default:
                    value(.weight, text: weightText)
                    value(.reps, text: "\(Int(r))" + (row.isPerSide ? " ×2" : ""))
                }
            }
            .focusable()
            .focused($crown)
            .digitalCrownRotation(crownBinding, from: 0, through: crownMax, by: crownStep, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            Button(store.label("done", "Done")) {
                store.complete(index, w: entry.mode == "cardio" ? nil : w, r: entry.mode == "reps" ? r : nil,
                               sec: entry.mode == "time" ? sec : nil, min: entry.mode == "cardio" ? min : nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .onAppear(perform: load)
    }

    private var caption: String {
        let sets = entry.sets
        let n = sets.filter { !$0.isWarmup }.count
        let k = sets.prefix(step.i + 1).filter { !$0.isWarmup }.count
        if row.isWarmup { return store.label("warmup", "Warm-up") }
        return store.label("setOf", "Set {0} of {1}").replacingOccurrences(of: "{0}", with: "\(k)").replacingOccurrences(of: "{1}", with: "\(n)")
    }

    private var weightText: String { "\(formatWeight(w)) \(store.unit)" }

    private func formatWeight(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%g", (v * 100).rounded() / 100)
    }

    @ViewBuilder
    private func value(_ field: Field, text: String) -> some View {
        Text(text)
            .font(.title3.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(editing == field ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.2)))
            .onTapGesture { editing = field; crown = true }
    }

    private var crownBinding: Binding<Double> {
        switch editing {
        case .weight: return $w
        case .reps: return $r
        case .sec: return $sec
        case .min: return $min
        }
    }
    private var crownStep: Double {
        switch editing {
        case .weight: return entry.mode == "reps" ? max(entry.step, 0.25) : 1.25
        case .reps, .min: return 1
        case .sec: return 5
        }
    }
    private var crownMax: Double {
        switch editing {
        case .weight: return 1000
        case .reps: return 200
        case .sec: return 3600
        case .min: return 600
        }
    }

    private func load() {
        w = row.w ?? 0
        r = row.isPerSide ? (row.sides?["L"]?.r ?? 0) : (row.r ?? 0)
        sec = row.sec ?? 0
        min = row.min ?? 0
        editing = entry.mode == "time" ? .sec : entry.mode == "cardio" ? .min : .reps
        crown = true
    }
}

struct RestView: View {
    @EnvironmentObject var store: WatchStore
    let rest: Rest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = rest.paused == true ? (rest.left ?? 0) : max(0, (rest.endsAt / 1000) - ctx.date.timeIntervalSince1970)
            VStack(spacing: 6) {
                Text(store.label("rest", "Rest")).font(.caption).foregroundStyle(.secondary)
                Text(clock(left)).font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                ProgressView(value: rest.total > 0 ? min(1, left / rest.total) : 0).tint(.accentColor)
                if let next = store.current {
                    let step = store.order[next]
                    Text("\(store.label("next", "Next")): \(store.entries[step.e].name)").font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                }
                HStack {
                    Button("+15") { store.addRest(15) }
                    Button(store.label("skip", "Skip")) { store.skipRest() }
                }
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.up))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }
}

/// Every set in order: a tap on one not done goes to it, a tap on one done unticks it.
struct SetListView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        List {
            ForEach(Array(store.order.enumerated()), id: \.offset) { idx, step in
                let entry = store.entries[step.e]
                let row = entry.sets[step.i]
                Button {
                    if row.done { store.undo(idx) } else { store.focus = idx }
                } label: {
                    HStack {
                        Image(systemName: row.done ? "checkmark.circle.fill" : "circle").foregroundStyle(row.done ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(entry.name).font(.caption).lineLimit(1)
                            Text(summary(entry, row)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ e: EntryView, _ s: SetView) -> String {
        switch e.mode {
        case "time": return "\(Int(s.sec ?? 0)) s" + (s.side.map { " · \($0)" } ?? "")
        case "cardio": return "\(Int(s.min ?? 0)) min"
        default:
            let w = s.w ?? 0
            let wt = w > 0 ? (w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(format: "%g", w)) + " \(store.unit) × " : ""
            return wt + "\(Int(s.r ?? 0))" + (s.isWarmup ? " · " + store.label("warmup", "Warm-up") : "")
        }
    }
}

/// Finish, and for a session run on the watch alone, discard.
struct ControlsView: View {
    @EnvironmentObject var store: WatchStore
    @State private var askDiscard = false

    var body: some View {
        VStack(spacing: 10) {
            Button(store.label("finish", "Finish")) { store.finish() }
                .buttonStyle(.borderedProminent).tint(.green)
            if store.isSolo {
                Button("Discard", role: .destructive) { askDiscard = true }
            } else {
                Text(store.label("onPhone", "Workout on your iPhone")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Discard this session?", isPresented: $askDiscard) {
            Button("Discard", role: .destructive) { store.discard() }
        }
    }
}
