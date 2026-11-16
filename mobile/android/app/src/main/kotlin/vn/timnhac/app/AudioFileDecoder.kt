package vn.timnhac.app

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.provider.OpenableColumns
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Decodes audio (or the audio track of a video) from a content URI with MediaExtractor +
 * MediaCodec, so no codec library is bundled with the app (section 9).
 * Only the selected segment is ever sent to the backend.
 */
class AudioFileDecoder(private val context: Context) {

    data class Segment(val pcm: ShortArray, val sampleRate: Int)

    private fun open(uri: Uri): Pair<MediaExtractor, MediaFormat> {
        val extractor = MediaExtractor()
        extractor.setDataSource(context, uri, null)
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                extractor.selectTrack(i)
                return extractor to format
            }
        }
        extractor.release()
        throw IllegalArgumentException("Tệp không có âm thanh")
    }

    fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment

    fun probe(uri: Uri): Map<String, Any?> {
        val (extractor, format) = open(uri)
        try {
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            return mapOf(
                "durationMs" to durationUs / 1000,
                "sampleRate" to format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                "channels" to format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                "mime" to format.getString(MediaFormat.KEY_MIME),
                "name" to displayName(uri),
            )
        } finally {
            extractor.release()
        }
    }

    /**
     * Streams mono PCM to [sink] from [startUs] on. [sink] receives (samples, count, sampleRate,
     * presentationTimeUs of the first sample) and returns false to stop.
     */
    private fun decode(uri: Uri, startUs: Long, sink: (ShortArray, Int, Int, Long) -> Boolean) {
        val (extractor, format) = open(uri)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        try {
            codec.configure(format, null, null, 0)
            codec.start()
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var idleAfterInput = 0
            while (idleAfterInput < 300) { // guard against decoders that never signal end of stream
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER && inputDone) idleAfterInput++
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val out = codec.outputFormat
                    rate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floatPcm = out.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        out.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (outIndex >= 0) {
                    var keepGoing = true
                    if (info.size > 0) {
                        val buf = codec.getOutputBuffer(outIndex)!!
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val mono = toMono(buf.order(ByteOrder.nativeOrder()), channels, floatPcm)
                        keepGoing = sink(mono, mono.size, rate, info.presentationTimeUs)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (!keepGoing || info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            runCatching { codec.stop() }
            codec.release()
            extractor.release()
        }
    }

    private fun toMono(buf: ByteBuffer, channels: Int, floatPcm: Boolean): ShortArray {
        val ch = max(channels, 1)
        return if (floatPcm) {
            val fb = buf.asFloatBuffer()
            val frames = fb.remaining() / ch
            ShortArray(frames) { i ->
                var sum = 0f
                for (c in 0 until ch) sum += fb.get(i * ch + c)
                ((sum / ch).coerceIn(-1f, 1f) * 32767).toInt().toShort()
            }
        } else {
            val sb = buf.asShortBuffer()
            val frames = sb.remaining() / ch
            ShortArray(frames) { i ->
                var sum = 0
                for (c in 0 until ch) sum += sb.get(i * ch + c)
                (sum / ch).toShort()
            }
        }
    }

    /** Mono PCM of [durationMs] starting at [startMs]. */
    fun segment(uri: Uri, startMs: Long, durationMs: Long): Segment {
        val startUs = startMs * 1000
        val endUs = (startMs + durationMs) * 1000
        var out = ShortArray(0)
        var length = 0
        var outRate = 44100
        decode(uri, startUs) { pcm, count, rate, ptsUs ->
            if (out.isEmpty()) {
                outRate = rate
                out = ShortArray((rate * durationMs / 1000).toInt() + rate)
            }
            for (i in 0 until count) {
                val t = ptsUs + i * 1_000_000L / rate
                if (t < startUs) continue
                if (t >= endUs || length >= out.size) return@decode false
                out[length++] = pcm[i]
            }
            true
        }
        return Segment(out.copyOf(length), outRate)
    }

    /** Peak per bucket (0..1) for the trim screen. Empty for very long files (> 20 min). */
    fun waveform(uri: Uri, buckets: Int): DoubleArray {
        val durationMs = (probe(uri)["durationMs"] as Long)
        if (durationMs <= 0 || durationMs > 20 * 60 * 1000) return DoubleArray(0)
        val peaks = DoubleArray(buckets)
        val totalUs = durationMs * 1000.0
        decode(uri, 0) { pcm, count, rate, ptsUs ->
            var i = 0
            while (i < count) {
                val t = ptsUs + i * 1_000_000L / rate
                val b = min(buckets - 1, (t / totalUs * buckets).toInt())
                val v = abs(pcm[i].toInt()) / 32768.0
                if (b >= 0 && v > peaks[b]) peaks[b] = v
                i += 4
            }
            true
        }
        return peaks
    }
}
