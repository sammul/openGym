import Foundation
import WatchConnectivity

/**
 * The iPhone end of the Apple Watch connection (docs/APPLE_WATCH.md). Owns the WCSession for the
 * life of the app, from launch, so a message the watch sends while the app is in the background
 * (or not running: iOS launches it for a transferUserInfo) is never missed.
 *
 * What it does is move text: the meaning of every message is the web app's (lib/watch.js).
 *  - phone → watch: the pack as a file (any size, latest wins), the live snapshot as application
 *    context (latest wins, survives the watch app being closed) and as a message when the watch
 *    app is open, so it shows at once.
 *  - watch → phone: commands land in an inbox file here. The web side reads it (WatchPlugin
 *    drain) and removes what it has applied (ack). Until then they stay, through a restart too.
 */
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    static let inboxChanged = Notification.Name("openGymWatchInboxChanged")

    private let queue = DispatchQueue(label: "opengym.watch.inbox")
    private var inbox: [[String: String]] = []
    private var pendingLive: String?
    private var pendingPack: String?

    private var inboxURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watch-inbox.json")
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        queue.sync { loadInbox() }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: phone → watch

    func sendLive(_ json: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { pendingLive = json; return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(["live": json])
        if session.isReachable {
            session.sendMessage(["live": json], replyHandler: nil, errorHandler: nil)
        }
    }

    func sendPack(_ json: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { pendingPack = json; return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        // Only the newest pack matters: one still on its way is called off.
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["kind"] as? String == "pack" {
            transfer.cancel()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opengym-watch-pack-\(UUID().uuidString).json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            session.transferFile(url, metadata: ["kind": "pack"])
        } catch {
            NSLog("openGym watch: pack not written: \(error.localizedDescription)")
        }
    }

    func status() -> [String: Bool] {
        guard WCSession.isSupported() else { return ["supported": false, "paired": false, "installed": false, "reachable": false] }
        let s = WCSession.default
        let on = s.activationState == .activated
        return ["supported": true, "paired": on && s.isPaired, "installed": on && s.isWatchAppInstalled, "reachable": on && s.isReachable]
    }

    // MARK: inbox

    func drain() -> [[String: String]] {
        queue.sync { inbox }
    }

    func ack(_ keys: [String]) {
        let gone = Set(keys)
        queue.sync {
            inbox.removeAll { gone.contains($0["key"] ?? "") }
            saveInbox()
        }
    }

    private func receive(_ payload: [String: Any]) {
        guard let json = payload["cmd"] as? String else { return }
        queue.sync {
            inbox.append(["key": UUID().uuidString, "json": json])
            saveInbox()
        }
        NotificationCenter.default.post(name: WatchBridge.inboxChanged, object: nil)
    }

    private func loadInbox() {
        guard let data = try? Data(contentsOf: inboxURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        inbox = list
    }

    private func saveInbox() {
        guard let data = try? JSONSerialization.data(withJSONObject: inbox) else { return }
        try? data.write(to: inboxURL, options: .atomic)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        DispatchQueue.main.async {
            if let pack = self.pendingPack { self.pendingPack = nil; self.sendPack(pack) }
            if let live = self.pendingLive { self.pendingLive = nil; self.sendLive(live) }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was paired: talk to that one from now on.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler(["ok": true])
    }

    // A session the watch ran alone comes as a file (it can be larger than a message may be).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "cmd",
              let json = try? String(contentsOf: file.fileURL, encoding: .utf8) else { return }
        receive(["cmd": json])
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
