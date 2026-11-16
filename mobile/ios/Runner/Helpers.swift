import AVFoundation
import Network
import UserNotifications

/// "Nghe thử" on the trim screen: plays `durationMs` from `startMs`. Main thread only.
final class PreviewPlayer {
    private var player: AVPlayer?
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
        let current = AVPlayer(playerItem: AVPlayerItem(url: url))
        player = current
        let start = CMTime(value: CMTimeValue(max(startMs, 0)), timescale: 1000)
        current.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, finished, self.player === current else { return }
                current.play()
                let work = DispatchWorkItem { [weak self] in self?.stop() }
                self.stopWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(durationMs, 0)), execute: work)
            }
        }
        return true
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        guard let current = player else { return }
        current.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Local notification when a sample saved offline has been recognised (F7).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
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
}

/// Reports whether the device has a usable network path.
final class ConnectivityWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vn.timnhac.connectivity")
    private let lock = NSLock()
    private var online = true
    private var known = false

    /// Called on the main thread whenever the state changes.
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let now = path.status == .satisfied
            self.lock.lock()
            let changed = !self.known || self.online != now
            self.online = now
            self.known = true
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
