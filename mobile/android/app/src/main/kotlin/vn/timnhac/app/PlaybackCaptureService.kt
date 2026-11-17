package vn.timnhac.app

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * "Nhạc đang phát trên máy" (Android 10+): records what other apps are playing for one
 * recognition, without bringing Tìm Nhạc to the front.
 *
 * Started by [CaptureConsentActivity] once the user has accepted the media projection. It runs as
 * a foreground service of type mediaProjection (required to hold a projection) and starts a
 * headless Flutter engine on `playbackCaptureMain` (lib/main.dart). The Dart side runs the same
 * listening session as the "Nghe" button over the `vn.timnhac/native` channel, which this service
 * answers with the playback capture instead of the microphone. Dart saves the result in the
 * history, posts the result notification and then calls `finishBackgroundTask`.
 */
@RequiresApi(29)
class PlaybackCaptureService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var projection: MediaProjection? = null
    private var engine: FlutterEngine? = null
    private var capture: AudioCapture? = null
    private var integrity: IntegrityHelper? = null
    private var finished = false
    private val watchdog = Runnable { finish() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            finish()
            return START_NOT_STICKY
        }
        // One capture at a time: the consent activity checks this flag before asking.
        if (running) return START_NOT_STICKY
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        val data = intent?.let { consentData(it) }
        if (resultCode != Activity.RESULT_OK || data == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        running = true
        // The projection may only be obtained once this is a foreground service of type mediaProjection.
        startForeground(NOTIFICATION_ID, progressNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        refreshTile()
        val proj = try {
            getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            null
        }
        if (proj == null) {
            finish()
            return START_NOT_STICKY
        }
        proj.registerCallback(object : MediaProjection.Callback() {
            // Stopped from the system UI ("Dừng chia sẻ"): keep what was recorded, record no more.
            override fun onStop() {
                capture?.stop()
            }
        }, main)
        projection = proj
        capture = AudioCapture(
            onLevel = {},
            createRecord = { rate, bytes -> AudioCapture.playbackRecord(proj, rate, bytes) },
            disableMicEffects = false,
        )
        integrity = IntegrityHelper(applicationContext)
        main.postDelayed(watchdog, WATCHDOG_MS)
        startDart()
        return START_NOT_STICKY
    }

    private fun consentData(intent: Intent): Intent? = if (Build.VERSION.SDK_INT >= 33) {
        intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
    } else {
        @Suppress("DEPRECATION")
        intent.getParcelableExtra(EXTRA_DATA)
    }

    private fun startDart() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            if (finished) return@ensureInitializationCompleteAsync
            val flutter = FlutterEngine(applicationContext)
            engine = flutter
            val messenger = flutter.dartExecutor.binaryMessenger
            MethodChannel(messenger, "vn.timnhac/native").setMethodCallHandler(::onMethodCall)
            // The listening session reads levels for its waveform; nothing is drawn here.
            EventChannel(messenger, "vn.timnhac/levels").setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {}
                override fun onCancel(arguments: Any?) {}
            })
            flutter.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "playbackCaptureMain")
            )
        }
    }

    /** The subset of MainActivity's channel that the background session uses. */
    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val capture = capture ?: return result.error("finished", "Đã dừng nghe", null)
        when (call.method) {
            "startRecording" -> result.success(capture.start(call.argument<Int>("maxSeconds") ?: 16))
            "snapshotRecording" -> background(result) {
                AudioCapture.encodePayload(capture.snapshot(call.argument<Int>("maxMs") ?: 6000), capture.sampleRate)
            }
            "stopRecording" -> background(result) { AudioCapture.encodePayload(capture.stop(), capture.sampleRate) }
            "cancelRecording" -> {
                capture.cancel()
                result.success(null)
            }
            "isOnline" -> result.success(ConnectivityWatcher.isOnline(this))
            "notify" -> {
                Notifier(applicationContext).show(
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<Int>("historyId"),
                )
                result.success(null)
            }
            // A service cannot ask; CaptureConsentActivity asked before starting it.
            "requestNotificationPermission" -> result.success(
                Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            )
            "integrityPrepare" -> {
                val number = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                    ?: return result.success(false)
                integrity?.prepare(number) { ok -> main.post { result.success(ok) } } ?: result.success(false)
            }
            "integrityToken" -> integrity?.token(call.argument<String>("requestHash")!!) { token ->
                main.post { result.success(token) }
            } ?: result.success(null)
            "appVersion" -> result.success(
                runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull()
            )
            "finishBackgroundTask" -> {
                result.success(null)
                main.post { finish() }
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            val outcome = runCatching(block)
            main.post {
                outcome.fold(
                    { result.success(it) },
                    { result.error("native_error", it.message ?: it.javaClass.simpleName, null) },
                )
            }
        }
    }

    private fun finish() {
        if (finished) return
        finished = true
        main.removeCallbacks(watchdog)
        capture?.cancel()
        capture = null
        projection?.stop()
        projection = null
        engine?.destroy()
        engine = null
        running = false
        refreshTile()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        finish()
        worker.shutdown()
        super.onDestroy()
    }

    private fun refreshTile() {
        runCatching { TileService.requestListeningState(this, ComponentName(this, RecognizeTileService::class.java)) }
    }

    private fun progressNotification(): Notification {
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(PROGRESS_CHANNEL, getString(R.string.capture_channel), NotificationManager.IMPORTANCE_LOW)
        )
        val cancel = PendingIntent.getService(
            this, 0, Intent(this, PlaybackCaptureService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, PROGRESS_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(getString(R.string.capture_listening_title))
            .setContentText(getString(R.string.capture_listening_body))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_stat_music), getString(R.string.cancel), cancel
                ).build()
            )
            .build()
    }

    companion object {
        const val EXTRA_RESULT_CODE = "vn.timnhac.RESULT_CODE"
        const val EXTRA_DATA = "vn.timnhac.PROJECTION_CONSENT"
        const val ACTION_CANCEL = "vn.timnhac.CANCEL_CAPTURE"
        private const val NOTIFICATION_ID = 2001
        private const val PROGRESS_CHANNEL = "playback_capture"

        /** Recording 12 s, recognising and saving never takes this long; a stuck run is cut. */
        private const val WATCHDOG_MS = 90_000L

        @Volatile
        var running = false
            private set
    }
}
