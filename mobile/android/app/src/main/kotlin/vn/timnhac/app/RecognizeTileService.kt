package vn.timnhac.app

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Quick Settings tile "Tìm Nhạc": recognises the music another app is playing without leaving
 * it. Enabled on Android 10+ only (res/values-v29/bools.xml), where playback capture exists.
 */
@RequiresApi(29)
class RecognizeTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = if (PlaybackCaptureService.running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.subtitle = getString(R.string.tile_subtitle)
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { openConsent() } else openConsent()
    }

    private fun openConsent() {
        val intent = Intent(this, CaptureConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
