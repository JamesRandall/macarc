import ArchimedesCore
import CSDL3
import Foundation

/// Bounded ring buffer between the emulation thread (producer, guest-rate
/// VIDC samples, resampled to the device's rate) and SDL's audio thread
/// (and so PipeWire or PulseAudio). Guest timing never waits on audio.
/// (The Mac app's AudioOutput, with SDL for AVAudioEngine.)
final class AudioOutput: AudioSink, @unchecked Sendable {
    private var stream: OpaquePointer?
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 48_000 * 2)
    private var readIndex = 0
    private var writeIndex = 0
    private let hostRate: Double = 48_000
    private var buffer = [Float](repeating: 0, count: 4096)
    private var mutedFlag = false
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedFlag }
        set { lock.lock(); mutedFlag = newValue; lock.unlock() }
    }

    private var resampler = BoxResampler(outputRate: 48_000)

    func start() {
        guard stream == nil else { return }
        guard SDL_InitSubSystem(SDL_INIT_AUDIO) else {
            NSLog("LinuxArch: no audio: \(String(cString: SDL_GetError()))")
            return
        }
        // About 10ms a buffer: enough to keep up, little enough to feel
        // immediate.
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, "512")
        var spec = SDL_AudioSpec(format: SDL_AUDIO_F32, channels: 2, freq: Int32(hostRate))
        let callback: SDL_AudioStreamCallback = { data, stream, additional, _ in
            guard let data, additional > 0 else { return }
            let output = Unmanaged<AudioOutput>.fromOpaque(data).takeUnretainedValue()
            output.fill(stream, count: Int(additional) / MemoryLayout<Float>.size)
        }
        guard let stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, callback,
                                                     Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("LinuxArch: no audio: \(String(cString: SDL_GetError()))")
            SDL_QuitSubSystem(SDL_INIT_AUDIO)
            return
        }
        self.stream = stream
        SDL_ResumeAudioStreamDevice(stream)
    }

    func stop() {
        guard let stream else { return }
        SDL_DestroyAudioStream(stream)
        self.stream = nil
        SDL_QuitSubSystem(SDL_INIT_AUDIO)
    }

    deinit { stop() }

    /// SDL's audio thread: `count` interleaved stereo floats, from the ring
    /// (silence when it's dry).
    private func fill(_ stream: OpaquePointer?, count: Int) {
        var remaining = count & ~1
        while remaining > 0 {
            let n = min(remaining, buffer.count)
            lock.lock()
            for i in stride(from: 0, to: n, by: 2) {
                if readIndex != writeIndex {
                    buffer[i] = ring[readIndex]; buffer[i + 1] = ring[readIndex + 1]
                    readIndex = (readIndex + 2) % ring.count
                } else {
                    buffer[i] = 0; buffer[i + 1] = 0
                }
                if mutedFlag { buffer[i] = 0; buffer[i + 1] = 0 }
            }
            lock.unlock()
            buffer.withUnsafeBufferPointer { _ = SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(n * MemoryLayout<Float>.size)) }
            remaining -= n
        }
    }

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
        lock.unlock()
    }
}
