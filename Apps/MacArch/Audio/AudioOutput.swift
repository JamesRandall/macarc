import ArchimedesCore
import AVFoundation

/// Bounded ring buffer between the emulation thread (producer, guest-rate
/// VIDC samples) and Core Audio (consumer). Guest timing never waits on audio.
final class AudioOutput: AudioSink, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 48_000 * 2)
    private var readIndex = 0
    private var writeIndex = 0
    private var hostRate: Double = 48_000
    var muted = false

    // Diagnostics: what Core Audio actually pulled (guarded by `lock`).
    private(set) var renderedFrames = 0
    private(set) var deliveredFrames = 0
    private(set) var peak: Float = 0
    private(set) var producedFrames = 0
    private(set) var engineError: String?

    private var resampler = BoxResampler(outputRate: 48_000)

    func start() {
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        hostRate = fmt.sampleRate > 0 ? fmt.sampleRate : 48_000
        resampler = BoxResampler(outputRate: hostRate)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: hostRate, channels: 2)!
        let node = AVAudioSourceNode(format: stereo) { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            for i in 0..<Int(frameCount) {
                if self.readIndex != self.writeIndex {
                    l[i] = self.ring[self.readIndex]; r[i] = self.ring[self.readIndex + 1]
                    self.readIndex = (self.readIndex + 2) % self.ring.count
                    self.deliveredFrames += 1
                    self.peak = max(self.peak, abs(l[i]), abs(r[i]))
                } else { l[i] = 0; r[i] = 0 }
                if self.muted { l[i] = 0; r[i] = 0 }
            }
            self.renderedFrames += Int(frameCount)
            self.lock.unlock()
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereo)
        do { try engine.start() } catch { engineError = "\(error)" }
    }

    /// Snapshot of the diagnostics counters, for the debug hook.
    var statistics: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return ["hostRate": "\(hostRate)", "engineRunning": "\(engine.isRunning)", "renderedFrames": "\(renderedFrames)",
                "deliveredFrames": "\(deliveredFrames)", "producedFrames": "\(producedFrames)", "peak": "\(peak)",
                "muted": "\(muted)", "engineError": engineError ?? "none"]
    }

    func stop() { engine.stop() }

    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
        resampler.push(left: left, right: right, inputRate: sampleRate) { l, r in emit(l, r) }
    }

    private func emit(_ l: Float, _ r: Float) {
        lock.lock()
        let next = (writeIndex + 2) % ring.count
        // Keep latency bounded (~100 ms): drop oldest samples when full.
        let fill = (writeIndex - readIndex + ring.count) % ring.count
        if fill > Int(hostRate * 0.1) * 2 { readIndex = (readIndex + 2) % ring.count }
        if next != readIndex { ring[writeIndex] = l; ring[writeIndex + 1] = r; writeIndex = next }
        producedFrames += 1
        lock.unlock()
    }
}
