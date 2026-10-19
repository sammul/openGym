import Foundation
import HealthKit

/**
 * The HealthKit workout that runs alongside an openGym session on the watch. It keeps the app
 * running with the wrist down (so the rest timer buzzes on time), shows the heart rate, and saves
 * the session to Health and the Fitness rings at the end. Optional: without Health access the
 * session runs and saves to openGym all the same.
 */
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    @Published private(set) var heartRate: Double?
    @Published private(set) var running = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func start(at date: Date = Date()) {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
        let share: Set = [HKObjectType.workoutType()]
        let read: Set = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        store.requestAuthorization(toShare: share, read: read) { [weak self] ok, _ in
            guard ok else { return }
            Task { @MainActor in self?.begin(at: date) }
        }
    }

    private func begin(at date: Date) {
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            s.startActivity(with: date)
            b.beginCollection(withStart: date) { _, _ in }
            running = true
        } catch {
            NSLog("openGym watch: no workout session: \(error.localizedDescription)")
        }
    }

    /// Ends the Health workout; `save` false throws it away (a session discarded on the watch).
    func end(save: Bool = true) {
        guard let s = session, let b = builder else { return }
        s.end()
        let now = Date()
        b.endCollection(withEnd: now) { _, _ in
            if save {
                b.finishWorkout { _, _ in }
            } else {
                b.discardWorkout()
            }
        }
        session = nil
        builder = nil
        running = false
        heartRate = nil
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        NSLog("openGym watch: workout session failed: \(error.localizedDescription)")
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let value = workoutBuilder.statistics(for: type)?.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) else { return }
        Task { @MainActor in self.heartRate = value }
    }
}
