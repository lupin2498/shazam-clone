import AVFoundation
import Flutter
import XCTest

@testable import Runner

/// Native audio code that cannot be exercised from Dart unit tests: the AAC/ADTS encoder,
/// the file decoder and the level maths. Runs on a simulator:
///   xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,...'
final class RunnerTests: XCTestCase {

    /// 440 Hz tone, peak 16000 (about -6 dBFS).
    private func tone(seconds: Double, rate: Int) -> [Int16] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map { Int16(16000 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
    }

    private struct AdtsInfo {
        var frames = 0
        var rate = 0
        var consumed = 0
    }

    /// Walks the frame headers exactly like `adts_duration()` in backend/app/audio.py.
    private func parseAdts(_ data: Data) throws -> AdtsInfo {
        let bytes = [UInt8](data)
        var info = AdtsInfo()
        var position = 0
        while position + 7 <= bytes.count {
            XCTAssertEqual(bytes[position], 0xFF, "sync byte at \(position)")
            XCTAssertEqual(bytes[position + 1] & 0xF6, 0xF0, "sync bits at \(position)")
            let index = Int((bytes[position + 2] >> 2) & 0x0F)
            let rate = try XCTUnwrap(index < AacEncoder.adtsRates.count ? AacEncoder.adtsRates[index] : nil)
            if info.rate == 0 { info.rate = rate }
            XCTAssertEqual(Int(bytes[position + 2] >> 6), 1, "profile must be AAC LC")
            let channels = (Int(bytes[position + 2] & 0x01) << 2) | Int(bytes[position + 3] >> 6)
            XCTAssertEqual(channels, 1, "mono")
            let length = (Int(bytes[position + 3] & 0x03) << 11) | (Int(bytes[position + 4]) << 3)
                | Int(bytes[position + 5] >> 5)
            if length < 7 {
                XCTFail("frame length \(length) at \(position)")
                break
            }
            info.frames += Int(bytes[position + 6] & 0x03) + 1
            position += length
        }
        info.consumed = position
        return info
    }

    private func temporaryFile(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(name)
    }

    /// Minimal 16-bit PCM WAV file.
    private func writeWav(_ pcm: [Int16], rate: Int, channels: Int = 1, name: String = "tone.wav") throws -> URL {
        var data = Data()
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = pcm.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(channels)
        append32(rate); append32(rate * channels * 2); append16(channels * 2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(byteCount)
        pcm.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        let url = temporaryFile(name)
        try data.write(to: url)
        return url
    }

    // MARK: - AAC encoder

    func testEncoderWritesAdtsFramesTheBackendCanMeasure() throws {
        for rate in [44100, 48000] {
            let aac = try AacEncoder.encode(tone(seconds: 3, rate: rate), sampleRate: rate)
            let info = try parseAdts(aac)
            XCTAssertEqual(info.consumed, aac.count, "no trailing bytes after the last frame")
            XCTAssertEqual(info.rate, rate)
            // The encoder adds a little priming; the backend allows 0.5 s over the sample length.
            XCTAssertEqual(Double(info.frames) * 1024 / Double(rate), 3.0, accuracy: 0.2)
            // 64 kbps is 8 kB per second.
            XCTAssertGreaterThan(aac.count, 3 * 4_000)
            XCTAssertLessThan(aac.count, 3 * 12_000)
        }
    }

    func testEncoderResamplesUnusualRatesTo44100() throws {
        let aac = try AacEncoder.encode(tone(seconds: 2, rate: 16000), sampleRate: 16000)
        let info = try parseAdts(aac)
        XCTAssertEqual(info.rate, 44100)
        XCTAssertEqual(Double(info.frames) * 1024 / 44100, 2.0, accuracy: 0.2)
    }

    func testEncoderReturnsNothingForEmptyInput() throws {
        XCTAssertTrue(try AacEncoder.encode([], sampleRate: 44100).isEmpty)
    }

    func testTwelveSecondSampleStaysUnder150Kilobytes() throws {
        // Design target (section 10): a 12 s sample is at most 150 KB.
        let aac = try AacEncoder.encode(tone(seconds: 12, rate: 44100), sampleRate: 44100)
        XCTAssertLessThan(aac.count, 150_000)
        XCTAssertEqual(Double(try parseAdts(aac).frames) * 1024 / 44100, 12.0, accuracy: 0.2)
    }

    func testAdtsHeaderMatchesAndroid() {
        // Same bytes as AacEncoder.kt for a 371-byte frame at 44.1 kHz mono.
        XCTAssertEqual([UInt8](AacEncoder.adtsHeader(frameLength: 371, freqIndex: 4)),
                       [0xFF, 0xF1, 0x50, 0x40, 0x2E, 0x7F, 0xFC])
    }

    // MARK: - Levels

    func testRmsAndLevel() {
        XCTAssertEqual(AudioCapture.rms([]), 0)
        XCTAssertEqual(AudioCapture.rms([Int16](repeating: 0, count: 100)), 0)
        XCTAssertEqual(AudioCapture.rms(tone(seconds: 1, rate: 44100)), 16000 / 32768.0 / 2.0.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(AudioCapture.level([Int16](repeating: 0, count: 100)), 0)
        XCTAssertEqual(AudioCapture.level([Int16](repeating: Int16.max, count: 100)), 1, accuracy: 0.01)
        // -30 dBFS is the middle of the -60..0 dB meter.
        XCTAssertEqual(AudioCapture.level([Int16](repeating: 1036, count: 100)), 0.5, accuracy: 0.01)
    }

    func testResamplerKeepsDuration() {
        let input = tone(seconds: 1, rate: 16000)
        XCTAssertEqual(Resampler.linear(input, from: 16000, to: 44100).count, 44100)
        XCTAssertEqual(Resampler.linear(input, from: 16000, to: 16000), input)
        XCTAssertTrue(Resampler.linear([], from: 16000, to: 44100).isEmpty)
    }

    // MARK: - File decoder

    func testDecoderProbesAndCutsAWavFile() throws {
        let url = try writeWav(tone(seconds: 5, rate: 22050), rate: 22050)
        let decoder = AudioFileDecoder()

        let probe = try decoder.probe(url)
        XCTAssertEqual(try XCTUnwrap(probe["durationMs"] as? Int), 5000, accuracy: 30)
        XCTAssertEqual(probe["name"] as? String, "tone.wav")

        let segment = try decoder.segment(url, startMs: 1000, durationMs: 2000)
        XCTAssertEqual(segment.sampleRate, 44100)
        XCTAssertEqual(segment.pcm.count, 2 * 44100, accuracy: 441)
        XCTAssertEqual(AudioCapture.rms(segment.pcm), 16000 / 32768.0 / 2.0.squareRoot(), accuracy: 0.03)

        // Asking past the end returns what is left, not an error.
        let tail = try decoder.segment(url, startMs: 4000, durationMs: 12000)
        XCTAssertEqual(tail.pcm.count, 44100, accuracy: 2205)
    }

    func testDecoderDownmixesStereo() throws {
        // Left channel carries the tone, right channel is silent: the mono mix is half as loud.
        let left = tone(seconds: 2, rate: 44100)
        var stereo = [Int16](repeating: 0, count: left.count * 2)
        for i in 0..<left.count { stereo[i * 2] = left[i] }
        let url = try writeWav(stereo, rate: 44100, channels: 2, name: "stereo.wav")
        let segment = try AudioFileDecoder().segment(url, startMs: 0, durationMs: 2000)
        XCTAssertEqual(segment.pcm.count, 2 * 44100, accuracy: 441)
        let rms = AudioCapture.rms(segment.pcm)
        XCTAssertGreaterThan(rms, 0.1)
        XCTAssertLessThan(rms, 0.3)
    }

    func testWaveformHasOnePeakPerBucket() throws {
        // First half silent, second half tone.
        let rate = 44100
        let pcm = [Int16](repeating: 0, count: 2 * rate) + tone(seconds: 2, rate: rate)
        let url = try writeWav(pcm, rate: rate)
        let peaks = try AudioFileDecoder().waveform(url, buckets: 40)
        XCTAssertEqual(peaks.count, 40)
        XCTAssertLessThan(peaks[5], 0.02)
        XCTAssertEqual(peaks[35], 16000 / 32768.0, accuracy: 0.06)
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testDecoderReadsBackTheEncodersOutput() throws {
        // Round trip through an .aac (ADTS) file: proves the framing is a valid AAC stream.
        let aac = try AacEncoder.encode(tone(seconds: 4, rate: 44100), sampleRate: 44100)
        let url = temporaryFile("roundtrip.aac")
        try aac.write(to: url)
        let decoder = AudioFileDecoder()
        XCTAssertEqual(try XCTUnwrap(try decoder.probe(url)["durationMs"] as? Int), 4000, accuracy: 250)
        let segment = try decoder.segment(url, startMs: 1000, durationMs: 2000)
        XCTAssertEqual(segment.pcm.count, 2 * 44100, accuracy: 4410)
        XCTAssertEqual(AudioCapture.rms(segment.pcm), 16000 / 32768.0 / 2.0.squareRoot(), accuracy: 0.05)
    }

    func testDecoderRejectsFilesWithoutAudio() throws {
        let url = temporaryFile("notes.txt")
        try Data("không phải âm thanh".utf8).write(to: url)
        XCTAssertThrowsError(try AudioFileDecoder().probe(url))
        XCTAssertThrowsError(try AudioFileDecoder().segment(url, startMs: 0, durationMs: 1000))
    }

    func testUriParsing() throws {
        XCTAssertEqual(try AudioFileDecoder.url(from: "file:///tmp/a%20b.mp3").path, "/tmp/a b.mp3")
        XCTAssertEqual(try AudioFileDecoder.url(from: "/tmp/a b.mp3").path, "/tmp/a b.mp3")
        XCTAssertThrowsError(try AudioFileDecoder.url(from: nil))
        XCTAssertThrowsError(try AudioFileDecoder.url(from: "https://example.com/a.mp3"))
    }

    // MARK: - Bridge payload

    func testEncodePayloadShape() throws {
        let payload = try NativeBridge.encodePayload(tone(seconds: 1, rate: 48000), sampleRate: 48000)
        XCTAssertEqual(payload["durationMs"] as? Int, 1000)
        XCTAssertEqual(try XCTUnwrap(payload["rms"] as? Double), 0.345, accuracy: 0.01)
        let aac = try XCTUnwrap(payload["aac"] as? FlutterStandardTypedData)
        XCTAssertEqual(try parseAdts(aac.data).rate, 48000)
    }
}
