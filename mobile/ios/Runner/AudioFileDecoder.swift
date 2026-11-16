import AVFoundation

/// Decodes audio (or the audio track of a video) with AVAssetReader, so no codec library is
/// bundled with the app (section 9). Only the selected segment is ever sent to the backend.
/// Counterpart of `AudioFileDecoder.kt` on Android.
final class AudioFileDecoder {

    struct Segment {
        let pcm: [Int16]
        let sampleRate: Int
    }

    enum DecodeError: LocalizedError {
        case badUri
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .badUri: return "Đường dẫn tệp không hợp lệ"
            case .noAudio: return "Tệp không có âm thanh"
            case .unreadable(let reason): return "Không đọc được tệp: \(reason)"
            }
        }
    }

    /// Rate of the PCM handed to the AAC encoder.
    static let segmentRate = 44100
    /// The trim screen only needs peaks, so the waveform is decoded at a lower rate.
    static let waveformRate = 11025
    static let maxWaveformMs = 20 * 60 * 1000

    static func url(from uri: String?) throws -> URL {
        guard let uri = uri, !uri.isEmpty else { throw DecodeError.badUri }
        if uri.hasPrefix("/") { return URL(fileURLWithPath: uri) }
        guard let url = URL(string: uri), url.isFileURL else { throw DecodeError.badUri }
        return url
    }

    private func open(_ url: URL) throws -> (AVURLAsset, AVAssetTrack) {
        // Precise timing matters for VBR MP3: without it, seeking to the segment start is off.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .audio).first else { throw DecodeError.noAudio }
        return (asset, track)
    }

    func probe(_ url: URL) throws -> [String: Any] {
        let (asset, track) = try open(url)
        var info: [String: Any] = [
            "durationMs": AudioFileDecoder.milliseconds(asset.duration),
            "name": url.lastPathComponent,
        ]
        if let description = track.formatDescriptions.first {
            let format = description as! CMAudioFormatDescription
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                info["sampleRate"] = Int(basic.mSampleRate)
                info["channels"] = Int(basic.mChannelsPerFrame)
            }
        }
        return info
    }

    private static func milliseconds(_ time: CMTime) -> Int {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? Int((seconds * 1000).rounded()) : 0
    }

    /// Streams mono 16-bit PCM at `rate` to `sink`, which returns false to stop.
    private func decode(_ url: URL, rate: Int, range: CMTimeRange?, sink: ([Int16]) -> Bool) throws {
        let (asset, track) = try open(url)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.unreadable("định dạng không hỗ trợ") }
        reader.add(output)
        if let range = range { reader.timeRange = range }
        guard reader.startReading() else {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "không giải mã được")
        }
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            if length < 2 { continue }
            var chunk = [Int16](repeating: 0, count: length / 2)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            if status != kCMBlockBufferNoErr { continue }
            if !sink(chunk) {
                reader.cancelReading()
                return
            }
        }
        if reader.status == .failed {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "không giải mã được")
        }
    }

    /// Mono PCM of `durationMs` starting at `startMs`.
    func segment(_ url: URL, startMs: Int, durationMs: Int) throws -> Segment {
        let rate = AudioFileDecoder.segmentRate
        let wanted = rate * max(durationMs, 0) / 1000
        var out = [Int16]()
        out.reserveCapacity(wanted)
        if wanted == 0 { return Segment(pcm: out, sampleRate: rate) }
        let range = CMTimeRange(
            start: CMTime(value: CMTimeValue(max(startMs, 0)), timescale: 1000),
            duration: CMTime(value: CMTimeValue(durationMs), timescale: 1000))
        try decode(url, rate: rate, range: range) { chunk in
            let room = wanted - out.count
            if room <= 0 { return false }
            out.append(contentsOf: chunk.prefix(room))
            return out.count < wanted
        }
        return Segment(pcm: out, sampleRate: rate)
    }

    /// Peak per bucket (0..1) for the trim screen. Empty for very long files (> 20 min).
    func waveform(_ url: URL, buckets: Int) throws -> [Double] {
        let (asset, _) = try open(url)
        let durationMs = AudioFileDecoder.milliseconds(asset.duration)
        if buckets <= 0 || durationMs <= 0 || durationMs > AudioFileDecoder.maxWaveformMs { return [] }
        let rate = AudioFileDecoder.waveformRate
        let total = max(Double(durationMs) / 1000.0 * Double(rate), 1)
        var peaks = [Double](repeating: 0, count: buckets)
        var position = 0
        try decode(url, rate: rate, range: nil) { chunk in
            for (i, sample) in chunk.enumerated() {
                let bucket = min(buckets - 1, Int(Double(position + i) / total * Double(buckets)))
                let value = Double(abs(Int(sample))) / 32768.0
                if value > peaks[bucket] { peaks[bucket] = value }
            }
            position += chunk.count
            return true
        }
        return peaks
    }
}
