package vn.timnhac.app

import android.Manifest
import android.app.StatusBarManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Bridge between Flutter and the Android APIs the app needs: microphone capture, AAC
 * encoding, file decoding, the system file picker, share intents, opening platform apps,
 * notifications, connectivity and Play Integrity.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newFixedThreadPool(2)

    private lateinit var capture: AudioCapture
    private lateinit var decoder: AudioFileDecoder
    private lateinit var preview: PreviewPlayer
    private lateinit var integrity: IntegrityHelper
    private lateinit var notifier: Notifier
    private lateinit var googleAuth: GoogleAuth
    private var connectivity: ConnectivityWatcher? = null

    private var levelSink: EventChannel.EventSink? = null
    private var sharedSink: EventChannel.EventSink? = null
    private var pendingShared: Map<String, Any?>? = null
    private var tapSink: EventChannel.EventSink? = null
    private var pendingTap: Int? = null
    private var micResult: MethodChannel.Result? = null
    private var notificationResult: MethodChannel.Result? = null
    private var pickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        capture = AudioCapture(onLevel = { level -> main.post { levelSink?.success(level) } })
        decoder = AudioFileDecoder(applicationContext)
        preview = PreviewPlayer(applicationContext)
        integrity = IntegrityHelper(applicationContext)
        notifier = Notifier(applicationContext)
        googleAuth = GoogleAuth(this)

        MethodChannel(messenger, "vn.timnhac/native").setMethodCallHandler(::onMethodCall)
        EventChannel(messenger, "vn.timnhac/levels").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { levelSink = events }
            override fun onCancel(arguments: Any?) { levelSink = null }
        })
        EventChannel(messenger, "vn.timnhac/shared_files").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sharedSink = events
                pendingShared?.let { events.success(it) }
                pendingShared = null
            }
            override fun onCancel(arguments: Any?) { sharedSink = null }
        })
        // Taps on a result notification: the history entry to open.
        EventChannel(messenger, "vn.timnhac/notification_taps").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                tapSink = events
                pendingTap?.let { events.success(it) }
                pendingTap = null
            }
            override fun onCancel(arguments: Any?) { tapSink = null }
        })
        EventChannel(messenger, "vn.timnhac/connectivity").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                connectivity = ConnectivityWatcher(applicationContext) { online -> main.post { events.success(online) } }
                    .also { it.start() }
            }
            override fun onCancel(arguments: Any?) {
                connectivity?.stop()
                connectivity = null
            }
        })
        handleShareIntent(intent)
        handleNotificationTap(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
        handleNotificationTap(intent)
    }

    private fun handleNotificationTap(intent: Intent?) {
        if (intent?.hasExtra(EXTRA_OPEN_HISTORY) != true) return
        val id = intent.getIntExtra(EXTRA_OPEN_HISTORY, -1)
        intent.removeExtra(EXTRA_OPEN_HISTORY) // not again after a configuration change
        if (id < 0) return
        val sink = tapSink
        if (sink != null) sink.success(id) else pendingTap = id
    }

    override fun onDestroy() {
        capture.cancel()
        preview.stop()
        connectivity?.stop()
        worker.shutdown()
        super.onDestroy()
    }

    /** Audio/video shared from another app ("Chia sẻ" → Tìm Nhạc) or opened with "Mở bằng". */
    private fun handleShareIntent(intent: Intent?) {
        val uri: Uri? = when (intent?.action) {
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        if (uri == null) return
        intent?.action = null // do not handle the same share twice
        worker.execute {
            val payload = mapOf("uri" to uri.toString(), "name" to decoder.displayName(uri))
            main.post {
                val sink = sharedSink
                if (sink != null) sink.success(payload) else pendingShared = payload
            }
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("native_error", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasMicPermission" -> result.success(hasPermission(Manifest.permission.RECORD_AUDIO))
            "shouldShowMicRationale" -> result.success(shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO))
            "requestMicPermission" -> {
                if (hasPermission(Manifest.permission.RECORD_AUDIO)) return result.success(true)
                micResult?.success(false)
                micResult = result
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
            }
            "openAppSettings" -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                result.success(null)
            }
            "startRecording" -> {
                if (!hasPermission(Manifest.permission.RECORD_AUDIO)) return result.error("permission", "Chưa có quyền micro", null)
                result.success(capture.start(call.argument<Int>("maxSeconds") ?: 16))
            }
            "snapshotRecording" -> background(result) {
                AudioCapture.encodePayload(capture.snapshot(call.argument<Int>("maxMs") ?: 6000), capture.sampleRate)
            }
            "stopRecording" -> background(result) { AudioCapture.encodePayload(capture.stop(), capture.sampleRate) }
            "cancelRecording" -> {
                capture.cancel()
                result.success(null)
            }
            "pickAudioFile" -> {
                pickResult?.success(null)
                pickResult = result
                val pick = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*", "application/ogg"))
                }
                try {
                    @Suppress("DEPRECATION")
                    startActivityForResult(pick, REQ_PICK)
                } catch (e: ActivityNotFoundException) {
                    pickResult = null
                    result.error("no_picker", "Không mở được trình chọn tệp", null)
                }
            }
            "probeAudio" -> background(result) { decoder.probe(Uri.parse(call.argument<String>("uri"))) }
            "audioWaveform" -> background(result) {
                decoder.waveform(Uri.parse(call.argument<String>("uri")), call.argument<Int>("buckets") ?: 200)
            }
            "encodeSegment" -> background(result) {
                val segment = decoder.segment(
                    Uri.parse(call.argument<String>("uri")),
                    (call.argument<Number>("startMs") ?: 0).toLong(),
                    (call.argument<Number>("durationMs") ?: 12000).toLong(),
                )
                AudioCapture.encodePayload(segment.pcm, segment.sampleRate)
            }
            "previewPlay" -> {
                try {
                    preview.play(
                        Uri.parse(call.argument<String>("uri")),
                        call.argument<Int>("startMs") ?: 0,
                        call.argument<Int>("durationMs") ?: 12000,
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "previewStop" -> {
                preview.stop()
                result.success(null)
            }
            "openUrl" -> result.success(openUrl(call.argument<String>("url")!!, call.argument<String>("package")))
            "shareText" -> {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, call.argument<String>("text"))
                }
                startActivity(Intent.createChooser(send, call.argument<String>("title")))
                result.success(null)
            }
            "installedPackages" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                result.success(packages.filter { isInstalled(it) })
            }
            "isOnline" -> result.success(ConnectivityWatcher.isOnline(this))
            "notify" -> {
                notifier.show(
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<Int>("historyId"),
                )
                result.success(null)
            }
            "playbackCaptureSupported" -> result.success(Build.VERSION.SDK_INT >= 29)
            "startPlaybackCapture" -> {
                if (Build.VERSION.SDK_INT < 29) return result.success(false)
                startActivity(Intent(this, CaptureConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(true)
            }
            "requestAddQuickSettingsTile" -> requestAddTile(result)
            "googleAuthorize" -> googleAuth.authorize(
                call.argument<Boolean>("interactive") ?: false,
                call.argument<String>("email"),
                call.argument<String>("invalidToken"),
                result,
            )
            "googleSignOut" -> googleAuth.signOut(call.argument<String>("email"), call.argument<String>("accessToken"), result)
            // Only the background capture engine has work to finish.
            "finishBackgroundTask" -> result.success(null)
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT < 33 || hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
                    return result.success(true)
                }
                notificationResult?.success(false)
                notificationResult = result
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
            }
            "integrityPrepare" -> {
                val number = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                    ?: return result.success(false)
                integrity.prepare(number) { ok -> main.post { result.success(ok) } }
            }
            "integrityToken" -> integrity.token(call.argument<String>("requestHash")!!) { token ->
                main.post { result.success(token) }
            }
            "appVersion" -> result.success(
                runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull()
            )
            else -> result.notImplemented()
        }
    }

    /**
     * Android 13+: the system dialog that adds the "Tìm Nhạc" tile to Quick Settings. Answers the
     * StatusBarManager result code (2 added, 1 already there, 0 refused, negative on error), or -1
     * below Android 13 where users add tiles by editing Quick Settings.
     */
    private fun requestAddTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) return result.success(-1)
        val manager = getSystemService(StatusBarManager::class.java) ?: return result.success(-1)
        try {
            manager.requestAddTileService(
                ComponentName(this, RecognizeTileService::class.java),
                getString(R.string.tile_label),
                Icon.createWithResource(this, R.drawable.ic_stat_music),
                mainExecutor,
            ) { code -> result.success(code) }
        } catch (e: Exception) {
            result.success(-1)
        }
    }

    /** Opens the platform's own app when installed, otherwise the browser (section 3, step 5). */
    private fun openUrl(url: String, pkg: String?): Boolean {
        val uri = Uri.parse(url)
        if (!pkg.isNullOrEmpty() && isInstalled(pkg)) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: ActivityNotFoundException) {
                // The app does not handle this kind of link (e.g. a search page): use the browser.
            }
        }
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun isInstalled(pkg: String): Boolean = try {
        if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(pkg, 0)
        }
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun hasPermission(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        when (requestCode) {
            REQ_MIC -> { micResult?.success(granted); micResult = null }
            REQ_NOTIFICATIONS -> { notificationResult?.success(granted); notificationResult = null }
        }
    }

    @Deprecated("Activity result API is not available on FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (googleAuth.onActivityResult(requestCode, resultCode, data)) return
        if (requestCode != REQ_PICK) return
        val result = pickResult ?: return
        pickResult = null
        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) return result.success(null)
        worker.execute {
            val payload = mapOf("uri" to uri.toString(), "name" to decoder.displayName(uri))
            main.post { result.success(payload) }
        }
    }

    companion object {
        /** Int extra of a result notification's intent: the history entry to open. */
        const val EXTRA_OPEN_HISTORY = "vn.timnhac.OPEN_HISTORY"
        private const val REQ_MIC = 4101
        private const val REQ_NOTIFICATIONS = 4102
        private const val REQ_PICK = 4103
    }
}
