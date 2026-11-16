import AVFoundation

/// Microphone capture as PCM 16-bit mono at the hardware sample rate (usually 48 kHz).
///
/// The audio session runs in `.measurement` mode, which switches off the system's gain
/// control and noise suppression: they distort the audio fingerprint (design doc, section 5).
/// It mixes with other apps, so music playing in another app keeps playing through the
/// speaker and the microphone hears it, as on Android. Counterpart of `AudioCapture.kt`.
///
/// Every method runs on `queue`, a serial queue owned by the caller; the tap block runs on
/// an audio thread, so the sample buffer is guarded by a lock.
final class AudioCapture {
    private let queue: DispatchQueue
    private let onLevel: (Double) -> Void
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var buffer: [Int16] = []
    private var capacity = 0
    private var rate = 44100

    init(queue: DispatchQueue, onLevel: @escaping (Double) -> Void) {
        self.queue = queue
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
            // defaultToSpeaker: the other app's music stays on the speaker (not the earpiece);
            // A2DP: Bluetooth headphones keep playing while the built-in microphone records.
            try session.setCategory(
                .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setPreferredSampleRate(44100)
            try session.setActive(true, options: [])
        } catch {
            return false
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
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

        guard installTap(on: engine) else {
            deactivateSession()
            return false
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            deactivateSession()
            return false
        }
        self.engine = engine
        observe(engine)
        return true
    }

    /// Installs the tap for the input's current format. False when there is no usable input.
    private func installTap(on engine: AVAudioEngine) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate >= 8000, format.channelCount > 0 else { return false }
        // 100 ms is the smallest buffer AVAudioNode documents; levels are still sent every 50 ms.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: nil) { [weak self] pcm, _ in
            self?.append(pcm)
        }
        return true
    }

    /// The engine stops itself when the input route or its format changes (a headset is
    /// plugged in) and when the session is interrupted (a call, Siri, an alarm). Recording
    /// then resumes into the same buffer instead of silently ending early.
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self = self, let engine = engine else { return }
            self.queue.async { self.resume(engine, reinstallTap: true) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self, weak engine] note in
            guard let self = self, let engine = engine,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self.queue.async { self.resume(engine, reinstallTap: false) }
        })
    }

    private func resume(_ engine: AVAudioEngine, reinstallTap: Bool) {
        // Recording may have been stopped while the notification was on its way.
        guard self.engine === engine else { return }
        if reinstallTap {
            engine.inputNode.removeTap(onBus: 0)
            // No input any more: keep what was captured, stop() returns it.
            guard installTap(on: engine) else { return }
        }
        if engine.isRunning { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        engine.prepare()
        try? engine.start()
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

        let chunkRate = Int(pcm.format.sampleRate.rounded())
        // One level per 50 ms, like Android, whatever the size of the tap's buffers.
        let window = max(chunkRate / 20, 1)
        var start = 0
        while start < chunk.count {
            let end = min(start + window, chunk.count)
            onLevel(AudioCapture.level(Array(chunk[start..<end])))
            start = end
        }

        lock.lock()
        defer { lock.unlock() }
        // The input format changed while recording (for example a headset microphone).
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
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
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
