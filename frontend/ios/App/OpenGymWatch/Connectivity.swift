import Foundation
import WatchConnectivity

/**
 * The watch end of the connection to the iPhone app (the phone end is ios/App/App/WatchBridge.swift).
 * In: the pack as a file, the live snapshot as application context or message. Out: commands, as a
 * message when the phone is in reach and queued with transferUserInfo when it is not, which the
 * system delivers in order whenever the two meet again. The phone counts each command id once,
 * so one that went both ways does no harm.
 */
final class Connectivity: NSObject, WCSessionDelegate {
    static let shared = Connectivity()

    var onPack: ((String) -> Void)?
    var onLive: ((String) -> Void)?
    var onReachable: ((Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isReachable: Bool { WCSession.isSupported() && WCSession.default.isReachable }

    func send(_ command: [String: Any]) {
        guard WCSession.isSupported(), let json = Self.text(command) else { return }
        let session = WCSession.default
        let payload: [String: Any] = ["cmd": json]
        if session.activationState == .activated && session.isReachable {
            session.sendMessage(payload, replyHandler: { _ in }, errorHandler: { _ in
                session.transferUserInfo(payload)
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// A whole session the watch ran alone: as a file, so its size never matters.
    func sendFile(_ command: [String: Any]) {
        guard WCSession.isSupported(), let json = Self.text(command) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opengym-session-\(UUID().uuidString).json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            WCSession.default.transferFile(url, metadata: ["kind": "cmd"])
        } catch {
            // Fall back to the queue; a session is small next to its limit in all but extreme cases.
            WCSession.default.transferUserInfo(["cmd": json])
        }
    }

    static func text(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        if let live = session.receivedApplicationContext["live"] as? String {
            DispatchQueue.main.async { self.onLive?(live) }
        }
        DispatchQueue.main.async { self.onReachable?(session.isReachable) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.onReachable?(reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let live = applicationContext["live"] as? String { DispatchQueue.main.async { self.onLive?(live) } }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let live = message["live"] as? String { DispatchQueue.main.async { self.onLive?(live) } }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "pack",
              let text = try? String(contentsOf: file.fileURL, encoding: .utf8) else { return }
        // The file is gone once this returns, so it is read here and handed over as text.
        DispatchQueue.main.async { self.onPack?(text) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
    }
}
