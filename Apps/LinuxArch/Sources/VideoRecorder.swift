import ArchimedesCore
import CGStreamer
import Foundation

/// Records the machine's picture and sound to a movie, with GStreamer (the
/// Mac app's VideoRecorder uses AVFoundation). Fed on the emulation thread:
/// frames with their guest time, and VIDC samples. Timestamps are guest
/// time, so the movie plays at the machine's speed whatever the PC did.
final class VideoRecorder: AudioSink, @unchecked Sendable {
    enum Codec {
        case h264, proRes

        /// The encoders to use, best first, as GStreamer elements.
        var videoEncoders: [String] {
            switch self {
            case .h264: [
                "x264enc bitrate=8000 speed-preset=fast ! video/x-h264,profile=high ! h264parse",
                "openh264enc bitrate=8000000 ! h264parse",
                "vah264enc bitrate=8000 ! h264parse",
            ]
            case .proRes: ["avenc_prores_ks profile=standard"]
            }
        }

        /// MP4 has AAC sound; MOV, as the Mac app's ProRes movies, 16-bit PCM.
        var audioEncoders: [String] {
            switch self {
            case .h264: ["avenc_aac bitrate=192000", "voaacenc bitrate=192000"]
            case .proRes: ["audio/x-raw,format=S16LE"]
            }
        }

        var muxer: String { self == .proRes ? "qtmux" : "mp4mux faststart=true" }
        var name: String { self == .proRes ? "ProRes" : "H.264" }
    }

    struct RecorderError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let url: URL
    private let codec: Codec
    private let encoders: (video: String, audio: String)
    private let lock = NSLock()
    private var pipeline: UnsafeMutablePointer<GstElement>?
    private var videoSource: UnsafeMutablePointer<GstAppSrc>?
    private var audioSource: UnsafeMutablePointer<GstAppSrc>?
    private var startTicks: UInt64?
    private var lastVideoTime: UInt64?
    private var width = 0, height = 0
    private var scaled: [UInt32] = []
    private var failed: Error?
    private var finished = false

    // Audio: resampled to 48 kHz stereo and written in 1024-frame packets.
    private static let sampleRate = 48_000.0
    private var resampler = BoxResampler(outputRate: VideoRecorder.sampleRate)
    private var pending: [Float] = []
    private var audioFramesWritten: Int64 = 0

    private static let initialised: Bool = gst_init_check(nil, nil, nil) != 0

    init(url: URL, codec: Codec) throws {
        self.url = url
        self.codec = codec
        encoders = try Self.encoders(codec)
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if let pipeline { gst_element_set_state(pipeline, GST_STATE_NULL) }
        release()
    }

    private func release() {
        if let videoSource { gst_object_unref(videoSource) }
        if let audioSource { gst_object_unref(audioSource) }
        if let pipeline { gst_object_unref(pipeline) }
        videoSource = nil; audioSource = nil; pipeline = nil
    }

    private static func available(_ chain: String) -> Bool {
        chain.split(separator: "!").allSatisfy { element in
            let name = element.split(separator: " ").first.map(String.init) ?? ""
            return name.contains("/") || la_gst_has_element(name) != 0
        }
    }

    /// The video and audio encoders to use, or why there aren't any.
    private static func encoders(_ codec: Codec) throws -> (video: String, audio: String) {
        guard initialised else { throw RecorderError(message: "GStreamer didn't start") }
        guard let video = codec.videoEncoders.first(where: available) else {
            let names = codec.videoEncoders.map { $0.split(separator: " ")[0] }.joined(separator: " or ")
            throw RecorderError(message: "No \(codec.name) encoder is installed (GStreamer's \(names))")
        }
        guard let audio = codec.audioEncoders.first(where: available) else {
            throw RecorderError(message: "No AAC encoder is installed (GStreamer's avenc_aac or voaacenc)")
        }
        return (video, audio)
    }

    /// Sets up the pipeline from the first frame (its display size).
    private func startVideo(_ f: VideoFrame) throws {
        // Encoders want even sizes.
        width = (f.width * f.scaleX + 1) & ~1
        height = (f.height * f.scaleY + 1) & ~1
        scaled = [UInt32](repeating: 0, count: width * height)
        // The frame rate is nominal: every frame has its own timestamp.
        let description = """
            appsrc name=video format=time block=true max-bytes=0 max-time=0 max-buffers=100 \
            caps=video/x-raw,format=BGRx,width=\(width),height=\(height),framerate=50/1,pixel-aspect-ratio=1/1 \
            ! videoconvert ! \(encoders.video) ! queue ! mux. \
            appsrc name=audio format=time block=false max-bytes=0 max-time=0 max-buffers=0 \
            caps=audio/x-raw,format=F32LE,rate=\(Int(Self.sampleRate)),channels=2,layout=interleaved \
            ! audioconvert ! \(encoders.audio) ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=0 ! mux. \
            \(codec.muxer) name=mux ! filesink name=file
            """
        var error: UnsafeMutablePointer<GError>?
        guard let p = gst_parse_launch(description, &error), error == nil else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "couldn't build the pipeline"
            if let error { g_error_free(error) }
            throw RecorderError(message: message)
        }
        pipeline = p
        la_gst_set_location(p, "file", url.path)
        videoSource = la_gst_app_src(p, "video")
        audioSource = la_gst_app_src(p, "audio")
        guard videoSource != nil, audioSource != nil else { throw RecorderError(message: "couldn't start recording") }
        if gst_element_set_state(p, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE {
            throw RecorderError(message: takeError(wait: false) ?? "couldn't start recording")
        }
    }

    private func takeError(wait: Bool) -> String? {
        guard let pipeline, let text = la_gst_error(pipeline, wait ? 1 : 0) else { return nil }
        defer { g_free(text) }
        return String(cString: text)
    }

    private func push(_ source: UnsafeMutablePointer<GstAppSrc>?, _ bytes: UnsafeRawBufferPointer, pts: UInt64, duration: UInt64) {
        guard let source, failed == nil else { return }
        guard let buffer = la_gst_buffer(bytes.baseAddress, gsize(bytes.count), GstClockTime(pts), GstClockTime(duration)) else {
            failed = RecorderError(message: "out of memory")
            return
        }
        // Takes the buffer; blocks while the picture's queue is full.
        if gst_app_src_push_buffer(source, buffer) != GST_FLOW_OK {
            failed = RecorderError(message: takeError(wait: false) ?? "the recording couldn't be written")
        } else if let message = takeError(wait: false) {
            failed = RecorderError(message: message)
        }
    }

    /// A completed frame at guest time `ticks`.
    func addFrame(_ f: VideoFrame, ticks: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard failed == nil, !finished, f.width > 1 else { return }
        if startTicks == nil {
            startTicks = ticks
            do { try startVideo(f) } catch { failed = error; return }
        }
        let time = (ticks - startTicks!) * 1_000_000_000 / UInt64(MasterClock.ticksPerSecond)
        if let lastVideoTime, time <= lastVideoTime { return }
        // Nearest-neighbour scale to the movie's size (modes can change).
        let w = width, h = height
        scaled.withUnsafeMutableBufferPointer { dst in
            f.pixels.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    let sy = y * f.height / h
                    for x in 0..<w { dst[y * w + x] = src[sy * f.width + x * f.width / w] }
                }
            }
        }
        scaled.withUnsafeBytes { push(videoSource, $0, pts: time, duration: UInt64.max) }
        lastVideoTime = time
        // Audio follows guest time too: while sound DMA is idle (or before
        // RISC OS starts it) no samples arrive, so pad with silence to keep
        // the tracks the same length and in sync.
        padAudio(toSeconds: Double(time) / 1e9 - 0.05)
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
        guard startTicks != nil, failed == nil, !finished else { return }
        resampler.push(left: left, right: right, inputRate: sampleRate) { l, r in pending.append(l); pending.append(r) }
        if pending.count >= 2048 { flushAudio() }
    }

    private func flushAudio() {
        let frames = pending.count / 2
        guard frames > 0 else { return }
        let rate = Int64(Self.sampleRate)
        let pts = UInt64(audioFramesWritten * 1_000_000_000 / rate)
        let end = UInt64((audioFramesWritten + Int64(frames)) * 1_000_000_000 / rate)
        pending.withUnsafeBytes { push(audioSource, $0, pts: pts, duration: end - pts) }
        audioFramesWritten += Int64(frames)
        pending.removeAll(keepingCapacity: true)
    }

    /// Finish the movie; `done` gets an error if it could not be written.
    func finish(_ done: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let started = startTicks != nil && pipeline != nil
        if started, failed == nil {
            // Audio up to the last frame.
            let end = Double(lastVideoTime ?? 0) / 1e9 + 1 / 50.0
            padAudio(toSeconds: end)
            flushAudio()
        }
        let error = failed
        lock.unlock()
        guard started else {
            try? FileManager.default.removeItem(at: url)
            done(error)
            return
        }
        // Waiting for the encoder to drain is done off the caller's thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            lock.lock(); defer { lock.unlock() }
            if let videoSource { gst_app_src_end_of_stream(videoSource) }
            if let audioSource { gst_app_src_end_of_stream(audioSource) }
            let message = takeError(wait: true)
            if let pipeline { gst_element_set_state(pipeline, GST_STATE_NULL) }
            release()
            done(error ?? message.map { RecorderError(message: $0) })
        }
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
