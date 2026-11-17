import AVFoundation
import Network
import UserNotifications

/// "Nghe thử" on the trim screen: plays `durationMs` from `startMs`. Main thread only.
final class PreviewPlayer {
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var stopWork: DispatchWorkItem?

    func play(_ url: URL, startMs: Int, durationMs: Int) -> Bool {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            // Playback category: the preview is audible even with the silent switch on.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            return false
        }
        let item = AVPlayerItem(url: url)
        let current = AVPlayer(playerItem: item)
        player = current
        let start = CMTime(value: CMTimeValue(max(startMs, 0)), timescale: 1000)
        // An item cannot be sought with a completion handler before it is ready to play
        // (AVFoundation raises an exception), so wait for that first.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            DispatchQueue.main.async {
                guard let self = self, self.player === current, self.statusObservation != nil else { return }
                switch status {
                case .readyToPlay:
                    self.statusObservation = nil
                    current.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async { self?.begin(current, durationMs: durationMs) }
                    }
                case .failed:
                    self.stop()
                default:
                    break
                }
            }
        }
        return true
    }

    private func begin(_ current: AVPlayer, durationMs: Int) {
        guard player === current else { return }
        current.play()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(durationMs, 0)), execute: work)
    }

    func stop() {
        statusObservation = nil
        stopWork?.cancel()
        stopWork = nil
        guard let current = player else { return }
        current.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Local notification when a sample saved offline has been recognised (F7). Tapping one that
/// carries a history id reports it through [onTap].
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main thread with the history id of a tapped notification.
    var onTap: ((Int) -> Void)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func show(title: String, body: String, historyId: Int? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let id = historyId { content.userInfo = ["historyId": id] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Without this the result would stay silent while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = (response.notification.request.content.userInfo["historyId"] as? NSNumber)?.intValue
        DispatchQueue.main.async {
            if let id = id { self.onTap?(id) }
            completionHandler()
        }
    }
}

/// Reports whether the device has a usable network path.
final class ConnectivityWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vn.timnhac.connectivity")
    private let lock = NSLock()
    private var online = true
    private var known = false
    private var interfaces = ""

    /// Called on the main thread when the network goes away, comes back or changes (for
    /// example Wi-Fi to cellular: Android reports each new default network too, and the
    /// offline queue retries on every `true`).
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let now = path.status == .satisfied
            let signature = path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
            self.lock.lock()
            let changed = !self.known || self.online != now || (now && self.interfaces != signature)
            self.online = now
            self.known = true
            self.interfaces = signature
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async { self.onChange?(now) }
            }
        }
        monitor.start(queue: queue)
    }

    /// True until the first path update arrives, like the Android side when it cannot tell.
    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    /// False before the first path update: the state is then announced through `onChange`.
    var isKnown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return known
    }
}
