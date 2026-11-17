package vn.timnhac.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager

/** "Nghe thử" on the trim screen: plays [durationMs] from [startMs]. */
class PreviewPlayer(private val context: Context) {
    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private val stopTask = Runnable { stop() }

    fun play(uri: Uri, startMs: Int, durationMs: Int) {
        stop()
        val p = MediaPlayer()
        try {
            p.setDataSource(context, uri)
            p.setOnPreparedListener {
                it.seekTo(startMs)
                it.start()
                handler.postDelayed(stopTask, durationMs.toLong())
            }
            p.setOnCompletionListener { stop() }
            p.setOnErrorListener { _, _, _ -> stop(); true }
            p.prepareAsync()
        } catch (e: Exception) {
            p.release() // not kept in [player]: nothing else would release it
            throw e
        }
        // Listeners run on this (main) thread, so none can fire before this assignment.
        player = p
    }

    fun stop() {
        handler.removeCallbacks(stopTask)
        player?.let {
            runCatching { it.stop() }
            it.release()
        }
        player = null
    }
}

/**
 * Play Integrity, standard requests: the provider is prepared once (slow), then each backend
 * call gets a token bound to its request hash (fast).
 */
class IntegrityHelper(private val context: Context) {
    private var provider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null

    fun prepare(cloudProjectNumber: Long, done: (Boolean) -> Unit) {
        val request = StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
            .setCloudProjectNumber(cloudProjectNumber)
            .build()
        IntegrityManagerFactory.createStandard(context).prepareIntegrityToken(request)
            .addOnSuccessListener { provider = it; done(true) }
            .addOnFailureListener { done(false) }
    }

    fun token(requestHash: String, done: (String?) -> Unit) {
        val p = provider ?: return done(null)
        val request = StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
            .setRequestHash(requestHash)
            .build()
        p.request(request)
            .addOnSuccessListener { done(it.token()) }
            .addOnFailureListener { done(null) }
    }
}

/**
 * Result notifications: a sample saved offline has been recognised (F7), or music playing in
 * another app has been recognised in the background. Tapping one opens the app, on the history
 * entry when [show] is given its id.
 */
class Notifier(private val context: Context) {
    fun show(title: String, body: String, historyId: Int? = null) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val id = nextId.getAndIncrement()
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { if (historyId != null) putExtra(MainActivity.EXTRA_OPEN_HISTORY, historyId) }
        // One request code per notification, so each keeps its own history id.
        val pending = PendingIntent.getActivity(
            context, id, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Kết quả nhận diện", NotificationManager.IMPORTANCE_DEFAULT)
            )
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .build()
        manager.notify(id, notification)
    }

    companion object {
        const val CHANNEL = "recognition_results"

        /** Shared by every Notifier in the process (the app and the background capture service). */
        private val nextId = java.util.concurrent.atomic.AtomicInteger(1000)
    }
}

class ConnectivityWatcher(context: Context, private val onChange: (Boolean) -> Unit) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val appContext = context.applicationContext
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = onChange(true)
        override fun onLost(network: Network) = onChange(isOnline(appContext))
    }

    fun start() {
        runCatching { manager?.registerDefaultNetworkCallback(callback) }
    }

    fun stop() {
        runCatching { manager?.unregisterNetworkCallback(callback) }
    }

    companion object {
        fun isOnline(context: Context): Boolean {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return true
            val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }
    }
}
