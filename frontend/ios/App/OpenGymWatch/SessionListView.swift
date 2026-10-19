import SwiftUI

/// Nothing running: the sessions from the pack, today's first. A workout started on the iPhone
/// takes over the screen by itself (RootView).
struct SessionListView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        List {
            if let sessions = store.pack?.sessions, !sessions.isEmpty {
                ForEach(sessions) { s in
                    Button { store.start(s) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if s.today == true {
                                Text(store.label("today", "Today")).font(.caption2).foregroundStyle(.tint)
                            }
                            Text(s.name).font(.headline).lineLimit(2)
                            Text(s.entries.map(\.name).joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } else {
                Text(store.label("noPack", "Open openGym on your iPhone once to send your routines."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("openGym")
    }
}
