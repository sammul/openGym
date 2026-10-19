import Foundation
import Capacitor

/**
 * The web app's handle on the Apple Watch (lib/watch-bridge.js). WatchBridge does the talking;
 * this only passes text across and says when the inbox has something new.
 *
 *   Watch.sendPack({ json })   Watch.sendLive({ json })   Watch.status()
 *   Watch.drain() -> { items: [{ key, json }] }            Watch.ack({ keys })
 *   Watch.addListener('inbox', () => drain())
 */
@objc(WatchPlugin)
public class WatchPlugin: CAPPlugin {
    private var observer: NSObjectProtocol?

    override public func load() {
        observer = NotificationCenter.default.addObserver(forName: WatchBridge.inboxChanged, object: nil, queue: .main) { [weak self] _ in
            self?.notifyListeners("inbox", data: [:])
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    @objc func sendPack(_ call: CAPPluginCall) {
        guard let json = call.getString("json") else { call.reject("json is required"); return }
        DispatchQueue.main.async { WatchBridge.shared.sendPack(json); call.resolve() }
    }

    @objc func sendLive(_ call: CAPPluginCall) {
        guard let json = call.getString("json") else { call.reject("json is required"); return }
        DispatchQueue.main.async { WatchBridge.shared.sendLive(json); call.resolve() }
    }

    @objc func status(_ call: CAPPluginCall) {
        call.resolve(WatchBridge.shared.status())
    }

    @objc func drain(_ call: CAPPluginCall) {
        call.resolve(["items": WatchBridge.shared.drain()])
    }

    @objc func ack(_ call: CAPPluginCall) {
        let keys = (call.getArray("keys") as? [String]) ?? []
        WatchBridge.shared.ack(keys)
        call.resolve()
    }
}
