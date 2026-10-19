import SwiftUI

@main
struct OpenGymWatchApp: App {
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        NavigationStack {
            if store.running {
                WorkoutView()
            } else {
                SessionListView()
            }
        }
        .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
