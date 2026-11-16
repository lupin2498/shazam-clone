import AVFoundation

/// Microphone capture as PCM 16-bit mono at the hardware sample rate (usually 48 kHz).
///
/// The audio session runs in `.measurement` mode, which switches off the system's gain
/// control and noise suppression: they distort the audio fingerprint (design doc, section 5).
/// Counterpart of `AudioCapture.kt` on Android.
///
/// `start`, `snapshot`, `stop` and `cancel` are called from one serial queue; the tap block
/// runs on an audio thread, so the sample buffer is guarded by a lock.
final class AudioCapture {
    private let onLevel: (Double) -> Void
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var buffer: [Int16] = []
    private var capacity = 0
    private var rate = 44100

    init(onLevel: @escaping (Double) -> Void) {
        self.onLevel = onLevel
    }

    /// Sample rate of the PCM returned by `snapshot` and `stop`.
    var sampleRate: Int {
        lock.lock()
        defer { lock.unlock() }
        return rate
    }

    /// Starts capturing up to `maxSeconds` seconds. The caller must hold the microphone permission.
    func start(maxSeconds: Int) -> Bool {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try? session.setPreferredSampleRate(44100)
            try session.setActive(true, options: [])
        } catch {
            return false
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No input route (or another app holds the microphone): installing a tap would raise.
        guard format.sampleRate >= 8000, format.channelCount > 0 else {
            deactivateSession()
            return false
        }
        let hardwareRate = Int(format.sampleRate.rounded())
        lock.lock()
        rate = hardwareRate
        capacity = hardwareRate * max(maxSeconds, 1)
        buffer = []
        buffer.reserveCapacity(capacity)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardwareRate / 20), format: nil) { [weak self] pcm, _ in
            self?.append(pcm)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            deactivateSession()
            return false
        }
        self.engine = engine
        return true
    }

    private func append(_ pcm: AVAudioPCMBuffer) {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        if frames <= 0 || channels <= 0 { return }
        let interleaved = pcm.format.isInterleaved
        var chunk = [Int16](repeating: 0, count: frames)
        if let data = pcm.floatChannelData {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += interleaved ? data[0][i * channels + c] : data[c][i]
                }
                // min/max keep NaN out: Int16(NaN) would trap.
                chunk[i] = Int16(max(-1, min(1, sum / Float(channels))) * 32767)
            }
        } else if let data = pcm.int16ChannelData {
            for i in 0..<frames {
                var sum = 0
                for c in 0..<channels {
                    sum += Int(interleaved ? data[0][i * channels + c] : data[c][i])
                }
                chunk[i] = Int16(sum / channels)
            }
        } else {
            return
        }
        onLevel(AudioCapture.level(chunk))

        let chunkRate = Int(pcm.format.sampleRate.rounded())
        lock.lock()
        defer { lock.unlock() }
        // The route changed while recording (for example a headset was plugged in).
        if chunkRate > 0 && chunkRate != rate {
            chunk = Resampler.linear(chunk, from: chunkRate, to: rate)
        }
        let room = capacity - buffer.count
        if room > 0 {
            buffer.append(contentsOf: chunk.prefix(room))
        }
    }

    /// Copy of the first `maxMs` milliseconds captured so far (recording continues).
    func snapshot(maxMs: Int) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let limit = min(buffer.count, rate * max(maxMs, 0) / 1000)
        return Array(buffer.prefix(limit))
    }

    /// Stops the microphone and returns everything captured.
    @discardableResult
    func stop() -> [Int16] {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            deactivateSession()
        }
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func cancel() {
        stop()
        lock.lock()
        buffer = []
        lock.unlock()
    }

    private func deactivateSession() {
        // Lets music that was playing in another app resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// RMS of the whole signal, 0..1 (1 = full scale). Used for the silence check.
    static func rms(_ pcm: [Int16]) -> Double {
        if pcm.isEmpty { return 0 }
        var sum = 0.0
        for sample in pcm {
            let value = Double(sample)
            sum += value * value
        }
        return (sum / Double(pcm.count)).squareRoot() / 32768.0
    }

    /// Meter level 0..1 on a -60..0 dBFS scale, for the waveform animation.
    static func level(_ pcm: [Int16]) -> Double {
        let value = rms(pcm)
        if value <= 0 { return 0 }
        let decibels = 20 * log10(value)
        return min(1, max(0, (decibels + 60) / 60))
    }
}
