package vn.timnhac.app

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder
import kotlin.math.min

/**
 * PCM 16-bit mono → AAC-LC in an ADTS stream (64 kbps by default: a 12 s sample is ~100 KB).
 * ADTS needs no container, and the backend can measure its duration from frame headers.
 */
object AacEncoder {
    private val ADTS_RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
    private const val TIMEOUT_US = 10_000L

    fun supportedRate(rate: Int): Int = when {
        rate in ADTS_RATES && rate <= 48000 -> rate
        rate > 48000 -> 48000
        else -> 44100
    }

    fun encode(pcmIn: ShortArray, rateIn: Int, bitRate: Int = 64_000): ByteArray {
        if (pcmIn.isEmpty()) return ByteArray(0)
        val rate = supportedRate(rateIn)
        val pcm = if (rate == rateIn) pcmIn else Resampler.linear(pcmIn, rateIn, rate)
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val out = ByteArrayOutputStream(pcm.size / 6)
        val freqIndex = ADTS_RATES.indexOf(rate)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val info = MediaCodec.BufferInfo()
            var offset = 0
            var inputDone = false
            val deadline = System.currentTimeMillis() + 20_000
            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        buf.clear()
                        val n = min(buf.capacity() / 2, pcm.size - offset)
                        val ptsUs = offset * 1_000_000L / rate
                        if (n <= 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            buf.order(ByteOrder.nativeOrder()).asShortBuffer().put(pcm, offset, n)
                            codec.queueInputBuffer(inIndex, 0, n * 2, ptsUs, 0)
                            offset += n
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!isConfig && info.size > 0) {
                        val ob = codec.getOutputBuffer(outIndex)!!
                        ob.position(info.offset)
                        ob.limit(info.offset + info.size)
                        out.write(adtsHeader(info.size + 7, freqIndex))
                        val frame = ByteArray(info.size)
                        ob.get(frame)
                        out.write(frame)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            runCatching { codec.stop() }
            codec.release()
        }
        return out.toByteArray()
    }

    private fun adtsHeader(frameLength: Int, freqIndex: Int, channels: Int = 1): ByteArray {
        val profile = 2 // AAC LC; ADTS stores profile - 1
        return byteArrayOf(
            0xFF.toByte(),
            0xF1.toByte(),
            (((profile - 1) shl 6) or (freqIndex shl 2) or (channels shr 2)).toByte(),
            (((channels and 3) shl 6) or (frameLength shr 11)).toByte(),
            ((frameLength and 0x7FF) shr 3).toByte(),
            (((frameLength and 7) shl 5) or 0x1F).toByte(),
            0xFC.toByte(),
        )
    }
}

object Resampler {
    fun linear(input: ShortArray, from: Int, to: Int): ShortArray {
        if (from == to || input.isEmpty()) return input
        val outLen = (input.size.toLong() * to / from).toInt()
        val out = ShortArray(outLen)
        val step = from.toDouble() / to
        for (i in 0 until outLen) {
            val pos = i * step
            val idx = pos.toInt()
            val frac = pos - idx
            val a = input[min(idx, input.size - 1)]
            val b = input[min(idx + 1, input.size - 1)]
            out[i] = (a + (b - a) * frac).toInt().toShort()
        }
        return out
    }
}
