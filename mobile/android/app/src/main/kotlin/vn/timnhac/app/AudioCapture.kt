package vn.timnhac.app

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Microphone capture: PCM 16-bit mono 44.1 kHz.
 *
 * Uses the VOICE_RECOGNITION source (no AGC / noise suppression per the Android CDD) and
 * additionally switches off any NS, AGC or AEC effect attached to the session, because
 * they distort the audio fingerprint (design doc, section 5).
 */
class AudioCapture(private val onLevel: (Double) -> Unit) {
    val sampleRate = 44100

    private val lock = Any()
    private var buffer = ShortArray(0)
    private var length = 0
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val effects = mutableListOf<AudioEffect>()

    @Volatile
    private var running = false

    /** Starts capturing up to [maxSeconds] seconds. Caller must hold RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start(maxSeconds: Int): Boolean {
        stop()
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) return false
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuffer * 2, sampleRate / 5 * 2),
            )
        } catch (e: Exception) {
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        disableEffects(rec.audioSessionId)
        synchronized(lock) {
            buffer = ShortArray(sampleRate * maxSeconds)
            length = 0
        }
        try {
            rec.startRecording()
        } catch (e: IllegalStateException) {
            rec.release()
            releaseEffects()
            return false
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            // Another app holds the microphone.
            rec.release()
            releaseEffects()
            return false
        }
        record = rec
        running = true
        thread = Thread({ readLoop(rec) }, "timnhac-capture").also { it.start() }
        return true
    }

    private fun readLoop(rec: AudioRecord) {
        val chunk = ShortArray(sampleRate / 20) // 50 ms
        while (running) {
            val n = rec.read(chunk, 0, chunk.size)
            if (n < 0) break
            if (n == 0) continue
            var full: Boolean
            synchronized(lock) {
                val m = min(n, buffer.size - length)
                if (m > 0) {
                    System.arraycopy(chunk, 0, buffer, length, m)
                    length += m
                }
                full = length >= buffer.size
            }
            onLevel(level(chunk, n))
            if (full) break
        }
    }

    /** Copy of the first [maxMs] milliseconds captured so far (recording continues). */
    fun snapshot(maxMs: Int): ShortArray = synchronized(lock) {
        buffer.copyOf(min(length, (sampleRate.toLong() * maxMs / 1000).toInt()))
    }

    /** Stops the microphone and returns everything captured. */
    fun stop(): ShortArray {
        running = false
        thread?.join(1000)
        thread = null
        record?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        record = null
        releaseEffects()
        return synchronized(lock) { buffer.copyOf(length) }
    }

    fun cancel() {
        stop()
        synchronized(lock) { length = 0 }
    }

    private fun disableEffects(session: Int) {
        try {
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session)?.let { it.enabled = false; effects.add(it) }
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session)?.let { it.enabled = false; effects.add(it) }
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session)?.let { it.enabled = false; effects.add(it) }
        } catch (_: Exception) {
            // Effects are optional; some devices throw when they are not supported.
        }
    }

    private fun releaseEffects() {
        effects.forEach { runCatching { it.release() } }
        effects.clear()
    }

    companion object {
        /** RMS of the whole signal, 0..1 (1 = full scale). Used for the silence check. */
        fun rms(pcm: ShortArray, count: Int = pcm.size): Double {
            if (count == 0) return 0.0
            var sum = 0.0
            for (i in 0 until count) {
                val s = pcm[i].toDouble()
                sum += s * s
            }
            return sqrt(sum / count) / 32768.0
        }

        /** Meter level 0..1 on a -60..0 dBFS scale, for the waveform animation. */
        fun level(pcm: ShortArray, count: Int): Double {
            val r = rms(pcm, count)
            if (r <= 0.0) return 0.0
            val db = 20 * log10(r)
            return ((db + 60) / 60).coerceIn(0.0, 1.0)
        }
    }
}
