import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

/// Bridge between Flutter and the iOS APIs the app needs: microphone capture, AAC encoding,
/// file decoding, the document picker, files opened from other apps, opening platform apps,
/// notifications and connectivity.
///
/// It implements the same channels as `MainActivity.kt` on Android (`vn.timnhac/native`,
/// `levels`, `shared_files`, `connectivity`), so the Dart side is identical on both platforms.
/// File URIs handed to Dart are `file://` URLs of copies inside the app's temporary directory.
final class NativeBridge: NSObject, FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate {
    private static var shared: NativeBridge?

    /// Android package → URL scheme of the same app on iOS, to rank installed apps first.
    /// Every scheme must also be listed under LSApplicationQueriesSchemes in Info.plist.
    static let appSchemes: [String: String] = [
        "com.google.android.youtube": "youtube",
        "com.google.android.apps.youtube.music": "youtubemusic",
        "com.spotify.music": "spotify",
        "com.soundcloud.android": "soundcloud",
        "com.apple.android.music": "music",
        "deezer.android.app": "deezer",
        "com.zing.mp3": "zingmp3",
        "ht.nct": "nhaccuatui",
        "com.aspiro.tidal": "tidal",
        "com.amazon.mp3": "amznmp3",
        "com.bandcamp.android": "bandcamp",
        "com.audiomack": "audiomack",
        "com.anghami": "anghami",
        "com.afmobi.boomplayer": "boomplay",
        "com.pandora.android": "pandora",
        "ru.yandex.music": "yandexmusic",
        "co.audius.app": "audius",
        "com.rhapsody": "napster",
    ]

    private let captureQueue = DispatchQueue(label: "vn.timnhac.capture", qos: .userInitiated)
    private let fileQueue = DispatchQueue(label: "vn.timnhac.files", qos: .userInitiated, attributes: .concurrent)

    private let decoder = AudioFileDecoder()
    private let preview = PreviewPlayer()
    private let notifier = Notifier()
    private let connectivity = ConnectivityWatcher()
    private var capture: AudioCapture!

    private weak var registrar: FlutterPluginRegistrar?
    private var methodChannel: FlutterMethodChannel?
    private var streamHandlers: [EventStream] = []

    private var levelSink: FlutterEventSink?
    private var sharedSink: FlutterEventSink?
    private var connectivitySink: FlutterEventSink?
    private var tapSink: FlutterEventSink?
    private var pendingShared: [String: Any]?
    private var pendingTap: Int?
    private var pickResult: FlutterResult?
    private lazy var googleAuth = GoogleAuth(anchor: { [weak self] in self?.presenter?.view.window })

    static func register(with registrar: FlutterPluginRegistrar) {
        let bridge = NativeBridge()
        bridge.attach(to: registrar)
        shared = bridge
    }

    private func attach(to registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        let messenger = registrar.messenger()
        capture = AudioCapture(queue: captureQueue) { [weak self] level in
            DispatchQueue.main.async { self?.levelSink?(level) }
        }

        let channel = FlutterMethodChannel(name: "vn.timnhac/native", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return result(FlutterMethodNotImplemented) }
            self.handle(call, result: result)
        }
        methodChannel = channel

        listen("vn.timnhac/levels", messenger,
               onListen: { [weak self] sink in self?.levelSink = sink },
               onCancel: { [weak self] in self?.levelSink = nil })
        listen("vn.timnhac/shared_files", messenger,
               onListen: { [weak self] sink in
                   guard let self = self else { return }
                   self.sharedSink = sink
                   if let pending = self.pendingShared {
                       self.pendingShared = nil
                       sink(pending)
                   }
               },
               onCancel: { [weak self] in self?.sharedSink = nil })
        listen("vn.timnhac/connectivity", messenger,
               onListen: { [weak self] sink in
                   guard let self = self else { return }
                   self.connectivitySink = sink
                   // Android reports the current network as soon as the callback is registered.
                   if self.connectivity.isKnown && self.connectivity.isOnline { sink(true) }
               },
               onCancel: { [weak self] in self?.connectivitySink = nil })

        // Taps on a result notification: the history entry to open.
        listen("vn.timnhac/notification_taps", messenger,
               onListen: { [weak self] sink in
                   guard let self = self else { return }
                   self.tapSink = sink
                   if let id = self.pendingTap {
                       self.pendingTap = nil
                       sink(id)
                   }
               },
               onCancel: { [weak self] in self?.tapSink = nil })

        connectivity.onChange = { [weak self] online in self?.connectivitySink?(online) }
        connectivity.start()
        notifier.onTap = { [weak self] id in
            guard let self = self else { return }
            if let sink = self.tapSink { sink(id) } else { self.pendingTap = id }
        }
        notifier.install()
        registrar.addSceneDelegate(self)
        // Before any file can arrive: nothing from a previous launch is still referenced.
        NativeBridge.removeOldCopies()
    }

    private func listen(
        _ name: String,
        _ messenger: FlutterBinaryMessenger,
        onListen: @escaping (@escaping FlutterEventSink) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let handler = EventStream(listen: onListen, cancel: onCancel)
        FlutterEventChannel(name: name, binaryMessenger: messenger).setStreamHandler(handler)
        streamHandlers.append(handler)
    }

    // MARK: - Method channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "hasMicPermission":
            result(NativeBridge.micGranted)
        case "shouldShowMicRationale":
            // iOS asks once; after a refusal only the Settings app can grant the microphone.
            result(false)
        case "requestMicPermission":
            NativeBridge.requestMic(result)
        case "openAppSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            result(nil)
        case "startRecording":
            guard NativeBridge.micGranted else {
                return result(FlutterError(code: "permission", message: "Chưa có quyền micro", details: nil))
            }
            let maxSeconds = args["maxSeconds"] as? Int ?? 16
            preview.stop()
            captureQueue.async {
                let started = self.capture.start(maxSeconds: maxSeconds)
                DispatchQueue.main.async { result(started) }
            }
        case "snapshotRecording":
            let maxMs = args["maxMs"] as? Int ?? 6000
            background(captureQueue, result) {
                try NativeBridge.encodePayload(self.capture.snapshot(maxMs: maxMs), sampleRate: self.capture.sampleRate)
            }
        case "stopRecording":
            background(captureQueue, result) {
                try NativeBridge.encodePayload(self.capture.stop(), sampleRate: self.capture.sampleRate)
            }
        case "cancelRecording":
            captureQueue.async {
                self.capture.cancel()
                DispatchQueue.main.async { result(nil) }
            }
        case "pickAudioFile":
            pickAudioFile(result)
        case "probeAudio":
            let uri = args["uri"] as? String
            background(fileQueue, result) { try self.decoder.probe(AudioFileDecoder.url(from: uri)) }
        case "audioWaveform":
            let uri = args["uri"] as? String
            let buckets = args["buckets"] as? Int ?? 200
            background(fileQueue, result) {
                try self.decoder.waveform(AudioFileDecoder.url(from: uri), buckets: buckets)
            }
        case "encodeSegment":
            let uri = args["uri"] as? String
            let startMs = args["startMs"] as? Int ?? 0
            let durationMs = args["durationMs"] as? Int ?? 12000
            background(fileQueue, result) {
                let segment = try self.decoder.segment(
                    AudioFileDecoder.url(from: uri), startMs: startMs, durationMs: durationMs)
                return try NativeBridge.encodePayload(segment.pcm, sampleRate: segment.sampleRate)
            }
        case "previewPlay":
            guard let url = try? AudioFileDecoder.url(from: args["uri"] as? String) else { return result(false) }
            result(preview.play(
                url, startMs: args["startMs"] as? Int ?? 0, durationMs: args["durationMs"] as? Int ?? 12000))
        case "previewStop":
            preview.stop()
            result(nil)
        case "openUrl":
            // Universal links open the platform's own app when it is installed, otherwise Safari.
            guard let text = args["url"] as? String, let url = URL(string: text) else { return result(false) }
            UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
        case "shareText":
            shareText(args["text"] as? String ?? "")
            result(nil)
        case "installedPackages":
            let packages = args["packages"] as? [String] ?? []
            result(packages.filter { NativeBridge.isInstalled($0) })
        case "isOnline":
            result(connectivity.isOnline)
        case "notify":
            notifier.show(
                title: args["title"] as? String ?? "", body: args["body"] as? String ?? "",
                historyId: (args["historyId"] as? NSNumber)?.intValue)
            result(nil)
        case "playbackCaptureSupported", "startPlaybackCapture":
            // iOS does not let an app capture what other apps play.
            result(false)
        case "requestAddQuickSettingsTile":
            result(-1)
        case "finishBackgroundTask":
            result(nil)
        case "googleAuthorize":
            guard let clientId = args["iosClientId"] as? String, !clientId.isEmpty else {
                return result(FlutterError(code: "not_configured", message: "GOOGLE_IOS_CLIENT_ID", details: nil))
            }
            googleAuth.authorize(interactive: args["interactive"] as? Bool ?? false, clientId: clientId) { outcome in
                switch outcome {
                case .success(let payload):
                    result(payload)
                case .failure(.notConfigured):
                    result(FlutterError(code: "not_configured", message: "GOOGLE_IOS_CLIENT_ID", details: nil))
                case .failure(.network(let message)):
                    result(FlutterError(code: "network", message: message, details: nil))
                case .failure(.google(let message)):
                    result(FlutterError(code: "google_error", message: message, details: nil))
                }
            }
        case "googleSignOut":
            googleAuth.signOut { result(nil) }
        case "requestNotificationPermission":
            notifier.requestPermission { granted in result(granted) }
        case "integrityPrepare":
            // Play Integrity is Android only; App Attest is not implemented yet.
            result(false)
        case "integrityToken":
            result(nil)
        case "appVersion":
            result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Runs `work` off the main thread and answers on it.
    private func background(_ queue: DispatchQueue, _ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
        queue.async {
            do {
                let value = try work()
                DispatchQueue.main.async { result(value) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    result(FlutterError(code: "native_error", message: message, details: nil))
                }
            }
        }
    }

    static func encodePayload(_ pcm: [Int16], sampleRate: Int) throws -> [String: Any] {
        let aac = try AacEncoder.encode(pcm, sampleRate: sampleRate)
        return [
            "aac": FlutterStandardTypedData(bytes: aac),
            "rms": AudioCapture.rms(pcm),
            "durationMs": sampleRate > 0 ? pcm.count * 1000 / sampleRate : 0,
        ]
    }

    // MARK: - Microphone permission

    private static var micGranted: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private static func requestMic(_ result: @escaping FlutterResult) {
        let answer: (Bool) -> Void = { granted in
            DispatchQueue.main.async { result(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: answer)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(answer)
        }
    }

    // MARK: - Other apps

    private static func isInstalled(_ androidPackage: String) -> Bool {
        guard let scheme = appSchemes[androidPackage], let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private var presenter: UIViewController? {
        var top = registrar?.viewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private func shareText(_ text: String) {
        guard let host = presenter else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // iPad shows the sheet as a popover, which needs an anchor.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        host.present(sheet, animated: true)
    }

    // MARK: - File picker

    private func pickAudioFile(_ result: @escaping FlutterResult) {
        pickResult?(nil)
        pickResult = nil
        guard let host = presenter else {
            return result(FlutterError(code: "no_picker", message: "Không mở được trình chọn tệp", details: nil))
        }
        // asCopy: the picked file is copied into the app's temporary directory, so it stays
        // readable without security-scoped access. No photo or media library permission is needed.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .movie], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        pickResult = result
        host.present(picker, animated: true)
        // A sheet swiped down may skip documentPickerWasCancelled; the Dart call must still end.
        picker.presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        pickResult?(nil)
        pickResult = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let result = pickResult
        pickResult = nil
        guard let url = urls.first else {
            result?(nil)
            return
        }
        result?(NativeBridge.payload(for: url))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickResult?(nil)
        pickResult = nil
    }

    private static func payload(for url: URL) -> [String: Any] {
        return ["uri": url.absoluteString, "name": url.lastPathComponent]
    }

    // MARK: - Files opened from other apps ("Mở bằng" / "Chia sẻ" → Tìm Nhạc)

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
        guard let contexts = connectionOptions?.urlContexts else { return false }
        return receive(contexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
        return receive(URLContexts)
    }

    private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
        let files = contexts.map { $0.url }.filter { $0.isFileURL }
        guard let url = files.first else { return false }
        fileQueue.async {
            guard let copy = NativeBridge.importShared(url) else { return }
            let payload = NativeBridge.payload(for: copy)
            DispatchQueue.main.async {
                if let sink = self.sharedSink {
                    sink(payload)
                } else {
                    self.pendingShared = payload
                }
            }
        }
        return true
    }

    private static var sharedDirectory: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
    }

    /// Copies a file handed over by another app into the temporary directory and removes the
    /// copy iOS left in Documents/Inbox, so nothing accumulates in the user-visible storage.
    private static func importShared(_ url: URL) -> URL? {
        let manager = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = sharedDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: target)
        } catch {
            return nil
        }
        if url.deletingLastPathComponent().lastPathComponent == "Inbox" {
            try? manager.removeItem(at: url)
        }
        return target
    }

    /// Deletes the copies made during earlier launches: files received from other apps and
    /// the document picker's own copies (`tmp/<bundle id>-Inbox`).
    private static func removeOldCopies() {
        let manager = FileManager.default
        try? manager.removeItem(at: sharedDirectory)
        if let bundleId = Bundle.main.bundleIdentifier {
            try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent("\(bundleId)-Inbox"))
        }
    }
}

/// Adapts closures to `FlutterStreamHandler`.
private final class EventStream: NSObject, FlutterStreamHandler {
    private let listen: (@escaping FlutterEventSink) -> Void
    private let cancel: () -> Void

    init(listen: @escaping (@escaping FlutterEventSink) -> Void, cancel: @escaping () -> Void) {
        self.listen = listen
        self.cancel = cancel
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        listen(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        cancel()
        return nil
    }
}
