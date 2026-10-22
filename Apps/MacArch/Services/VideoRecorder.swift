import ArchimedesCore
import AVFoundation
import CoreVideo

/// Records the machine's picture and sound to a movie. Fed on the emulation
/// thread: frames with their guest time, and VIDC samples. Timestamps are
/// guest time, so the movie plays at the machine's speed whatever the Mac did.
final class VideoRecorder: AudioSink, @unchecked Sendable {
    enum Codec { case h264, proRes }

    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let audio: AVAssetWriterInput
    private let codec: Codec
    private let lock = NSLock()
    private var startTicks: UInt64?
    private var lastVideoTime = CMTime.negativeInfinity
    private var width = 0, height = 0
    private var failed: Error?

    // Audio: resampled to 48 kHz stereo and written in 1024-frame packets.
    private static let sampleRate = 48_000.0
    private var resampler = BoxResampler(outputRate: VideoRecorder.sampleRate)
    private var pending: [Float] = []
    private var audioFramesWritten: Int64 = 0
    private let audioFormat: CMAudioFormatDescription

    init(url: URL, codec: Codec) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: codec == .proRes ? .mov : .mp4)
        self.codec = codec
        var asbd = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        audioFormat = fmt!
        let audioSettings: [String: Any] = codec == .proRes
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2,
               AVEncoderBitRateKey: 192_000]
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
    }

    /// Set up the video track from the first frame (its display size).
    private func startVideo(_ f: VideoFrame) {
        width = f.width * f.scaleX
        height = f.height * f.scaleY
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .proRes ? AVVideoCodecType.proRes422 : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        v.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(v)
        writer.add(audio)
        video = v
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    /// A completed frame at guest time `ticks`.
    func addFrame(_ f: VideoFrame, ticks: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard failed == nil, f.width > 1 else { return }
        if startTicks == nil { startTicks = ticks; startVideo(f) }
        guard let video, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        let time = CMTime(value: CMTimeValue(ticks - startTicks!), timescale: CMTimeScale(MasterClock.ticksPerSecond))
        guard time > lastVideoTime, video.isReadyForMoreMediaData else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let dst = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        // Nearest-neighbour scale to the movie's size (modes can change).
        f.pixels.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let sy = y * f.height / height
                for x in 0..<width { dst[y * stride + x] = src[sy * f.width + x * f.width / width] }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: time) { lastVideoTime = time } else { failed = writer.error }
        // Audio follows guest time too: while sound DMA is idle (or before
        // RISC OS starts it) no samples arrive, so pad with silence to keep
        // the tracks the same length and in sync.
        padAudio(toSeconds: time.seconds - 0.05)
    }

    /// Appends silence until the audio reaches `seconds` of movie time.
    private func padAudio(toSeconds seconds: Double) {
        let target = Int64(seconds * Self.sampleRate)
        let have = audioFramesWritten + Int64(pending.count / 2)
        guard target > have else { return }
        pending += [Float](repeating: 0, count: Int(target - have) * 2)
        flushAudio()
    }

    // AudioSink: VIDC samples at the guest byte rate.
    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard startTicks != nil, failed == nil else { return }
        resampler.push(left: left, right: right, inputRate: sampleRate) { l, r in pending.append(l); pending.append(r) }
        if pending.count >= 2048 { flushAudio() }
    }

    private func flushAudio() {
        let frames = pending.count / 2
        guard frames > 0 else { return }
        // Not ready: keep the samples (up to 5 s) rather than leave a gap.
        guard audio.isReadyForMoreMediaData else {
            let cap = Int(Self.sampleRate) * 5 * 2
            if pending.count > cap { pending.removeFirst(pending.count - cap) }
            return
        }
        var block: CMBlockBuffer?
        let bytes = frames * 8
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        pending.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let time = CMTime(value: audioFramesWritten, timescale: CMTimeScale(Self.sampleRate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        if let sample, audio.append(sample) { audioFramesWritten += Int64(frames) }
        pending.removeAll(keepingCapacity: true)
    }

    /// Finish the movie; `done` gets an error if it could not be written.
    func finish(_ done: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        if startTicks != nil {
            // Audio up to the last frame; give the writer a moment rather
            // than drop the tail.
            let end = lastVideoTime.isNumeric ? lastVideoTime.seconds + 1 / 50.0 : 0
            let target = Int64(end * Self.sampleRate)
            let have = audioFramesWritten + Int64(pending.count / 2)
            if target > have { pending += [Float](repeating: 0, count: Int(target - have) * 2) }
            for _ in 0..<100 where !pending.isEmpty {
                if audio.isReadyForMoreMediaData { flushAudio() } else { usleep(10_000) }
            }
        }
        let started = startTicks != nil, error = failed
        lock.unlock()
        guard started else { writer.cancelWriting(); done(nil); return }
        video?.markAsFinished()
        audio.markAsFinished()
        writer.finishWriting { [writer] in done(error ?? writer.error) }
    }
}

/// Fans VIDC samples out to the speakers and, while recording, the recorder.
final class AudioTee: AudioSink, @unchecked Sendable {
    let output: AudioSink
    private let lock = NSLock()
    private var _recorder: AudioSink?
    var recorder: AudioSink? {
        get { lock.lock(); defer { lock.unlock() }; return _recorder }
        set { lock.lock(); _recorder = newValue; lock.unlock() }
    }

    init(output: AudioSink) { self.output = output }

    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
        output.audioSamples(left: left, right: right, count: count, sampleRate: sampleRate)
        lock.lock(); let r = _recorder; lock.unlock()
        r?.audioSamples(left: left, right: right, count: count, sampleRate: sampleRate)
    }
}
