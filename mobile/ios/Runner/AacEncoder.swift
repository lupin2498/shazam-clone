import AVFoundation

/// PCM 16-bit mono → AAC-LC in an ADTS stream (64 kbps by default: a 12 s sample is ~100 KB).
/// ADTS needs no container, and the backend measures its duration from the frame headers.
/// Counterpart of `AacEncoder.kt` on Android: the two must produce the same framing.
enum AacEncoder {
    static let adtsRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    enum EncodeError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Không khởi tạo được bộ mã hóa AAC"
            case .failed(let reason): return "Mã hóa AAC lỗi: \(reason)"
            }
        }
    }

    /// The encoder is only fed 44.1 or 48 kHz; any other rate (for example a Bluetooth
    /// headset microphone at 16 kHz) is resampled to 44.1 kHz first.
    static func supportedRate(_ rate: Int) -> Int {
        return (rate == 44100 || rate == 48000) ? rate : 44100
    }

    static func encode(_ pcmIn: [Int16], sampleRate rateIn: Int, bitRate: Int = 64_000) throws -> Data {
        if pcmIn.isEmpty || rateIn <= 0 { return Data() }
        let rate = supportedRate(rateIn)
        let pcm = rate == rateIn ? pcmIn : Resampler.linear(pcmIn, from: rateIn, to: rate)
        if pcm.isEmpty { return Data() }

        guard let freqIndex = adtsRates.firstIndex(of: rate),
              let inFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: false)
        else { throw EncodeError.unavailable }

        var outDescription = AudioStreamBasicDescription(
            mSampleRate: Double(rate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let outFormat = AVAudioFormat(streamDescription: &outDescription),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw EncodeError.unavailable }
        converter.bitRate = applicableBitRate(converter, wanted: bitRate)

        // Input is handed over in chunks no larger than the converter asks for; one buffer is
        // reused because the converter is done with it by the time it asks for more.
        let chunkCapacity = 8192
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunkCapacity)),
              let inSamples = inBuffer.int16ChannelData?[0]
        else { throw EncodeError.unavailable }
        var offset = 0
        let inputBlock: AVAudioConverterInputBlock = { requested, status in
            let remaining = pcm.count - offset
            if remaining <= 0 {
                status.pointee = .endOfStream
                return nil
            }
            let count = min(remaining, chunkCapacity, max(Int(requested), 1))
            pcm.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    memcpy(inSamples, base + offset, count * MemoryLayout<Int16>.size)
                }
            }
            inBuffer.frameLength = AVAudioFrameCount(count)
            offset += count
            status.pointee = .haveData
            return inBuffer
        }

        let outBuffer = AVAudioCompressedBuffer(
            format: outFormat, packetCapacity: 16, maximumPacketSize: max(converter.maximumOutputPacketSize, 2048))
        var out = Data(capacity: pcm.count / 6 + 1024)
        var rounds = pcm.count / 1024 + 64 // far more than needed; guards against a converter that never ends
        while rounds > 0 {
            rounds -= 1
            outBuffer.packetCount = 0
            outBuffer.byteLength = 0
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError, withInputFrom: inputBlock)
            if status == .error {
                throw EncodeError.failed(convertError?.localizedDescription ?? "AVAudioConverter")
            }
            appendPackets(of: outBuffer, to: &out, freqIndex: freqIndex)
            if status == .endOfStream { break }
        }
        return out
    }

    /// 64 kbps is valid for mono 44.1/48 kHz; still, take the nearest rate the encoder offers.
    private static func applicableBitRate(_ converter: AVAudioConverter, wanted: Int) -> Int {
        guard let rates = converter.applicableEncodeBitRates?.map({ $0.intValue }), !rates.isEmpty else {
            return wanted
        }
        return rates.min(by: { abs($0 - wanted) < abs($1 - wanted) }) ?? wanted
    }

    private static func appendPackets(of buffer: AVAudioCompressedBuffer, to out: inout Data, freqIndex: Int) {
        let count = Int(buffer.packetCount)
        if count == 0 { return }
        let base = UnsafeRawPointer(buffer.data)
        if let descriptions = buffer.packetDescriptions {
            for i in 0..<count {
                let size = Int(descriptions[i].mDataByteSize)
                if size <= 0 { continue }
                let start = Int(descriptions[i].mStartOffset)
                out.append(adtsHeader(frameLength: size + 7, freqIndex: freqIndex))
                out.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: size)
            }
        } else {
            let size = Int(buffer.byteLength)
            if size <= 0 { return }
            out.append(adtsHeader(frameLength: size + 7, freqIndex: freqIndex))
            out.append(base.assumingMemoryBound(to: UInt8.self), count: size)
        }
    }

    /// 7-byte ADTS header without CRC: MPEG-4, AAC LC, one raw data block per frame.
    static func adtsHeader(frameLength: Int, freqIndex: Int, channels: Int = 1) -> Data {
        let profile = 2 // AAC LC; ADTS stores profile - 1
        return Data([
            0xFF,
            0xF1,
            UInt8(((profile - 1) << 6) | (freqIndex << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength & 0x7FF) >> 3),
            UInt8(((frameLength & 7) << 5) | 0x1F),
            0xFC,
        ])
    }
}

enum Resampler {
    static func linear(_ input: [Int16], from: Int, to: Int) -> [Int16] {
        if from == to || input.isEmpty || from <= 0 || to <= 0 { return input }
        let outLength = Int(Int64(input.count) * Int64(to) / Int64(from))
        var out = [Int16](repeating: 0, count: outLength)
        let step = Double(from) / Double(to)
        let last = input.count - 1
        for i in 0..<outLength {
            let position = Double(i) * step
            let index = Int(position)
            let fraction = position - Double(index)
            let a = Double(input[min(index, last)])
            let b = Double(input[min(index + 1, last)])
            out[i] = Int16(max(-32768, min(32767, (a + (b - a) * fraction).rounded())))
        }
        return out
    }
}
