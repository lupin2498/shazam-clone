package vn.timnhac.app

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast

/**
 * Invisible step between the Quick Settings tile (or the in-app button) and
 * [PlaybackCaptureService]: asks for the microphone and notification permissions if needed,
 * explains once why Android is about to ask to "record the screen", then asks for the media
 * projection. It has its own task, so finishing it returns to the app the user was watching.
 */
class CaptureConsentActivity : Activity() {
    private var asked = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < 29) return finish()
        if (PlaybackCaptureService.running) {
            Toast.makeText(this, R.string.capture_already_running, Toast.LENGTH_SHORT).show()
            return finish()
        }
        // Recreated while the system dialog is open: its result still comes back here.
        asked = savedInstanceState?.getBoolean(STATE_ASKED) ?: false
        if (asked) return
        val missing = buildList {
            if (!granted(Manifest.permission.RECORD_AUDIO)) add(Manifest.permission.RECORD_AUDIO)
            // Results arrive as notifications.
            if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS)) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (missing.isEmpty()) explainThenAsk() else requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_ASKED, asked)
    }

    private fun granted(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        // Playback capture needs RECORD_AUDIO; without notifications the result is still saved in the history.
        if (!granted(Manifest.permission.RECORD_AUDIO)) {
            Toast.makeText(this, R.string.capture_needs_mic, Toast.LENGTH_LONG).show()
            return finish()
        }
        explainThenAsk()
    }

    private fun explainThenAsk() {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (prefs.getBoolean(KEY_EXPLAINED, false)) return askProjection()
        AlertDialog.Builder(this)
            .setTitle(R.string.capture_explain_title)
            .setMessage(R.string.capture_explain_body)
            .setPositiveButton(R.string.capture_continue) { _, _ ->
                prefs.edit().putBoolean(KEY_EXPLAINED, true).apply()
                askProjection()
            }
            .setNegativeButton(R.string.cancel) { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }

    private fun askProjection() {
        val manager = getSystemService(MediaProjectionManager::class.java)
        // The whole display, not one app: the audio of every app is what is captured.
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        try {
            asked = true
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PROJECTION)
        } catch (e: ActivityNotFoundException) {
            finish()
        }
    }

    @Deprecated("Activity result API is not used in this plain Activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PROJECTION && resultCode == RESULT_OK && data != null) {
            startForegroundService(
                Intent(this, PlaybackCaptureService::class.java)
                    .putExtra(PlaybackCaptureService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(PlaybackCaptureService.EXTRA_DATA, data)
            )
        }
        finish()
    }

    companion object {
        private const val REQ_PERMISSIONS = 5101
        private const val REQ_PROJECTION = 5102
        private const val STATE_ASKED = "asked"
        private const val PREFS = "timnhac_native"
        private const val KEY_EXPLAINED = "playback_capture_explained"
    }
}
