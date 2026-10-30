import Foundation

// The floppy drives' mechanical noises: the motor spinning up, running and
// down, the head stepping and seeking.
//
// As MacBeeb does it, after b2 (BBCMicro.cpp's StepSound and
// UpdateDiscDriveSound, Copyright (C) Tom Seddon, GPLv3), with MAME's
// recordings of a 3.5" drive (CC0). The controllers announce a seek with its
// steps and step rate, so a seek of more than one step plays MAME's seek
// sample for that rate (b2's choice of it) for as long as the seek lasts.

/// A drive's samples, mono, at their own rate.
public struct DiscDriveSounds: Sendable {
    public enum Sound: Int, CaseIterable, Sendable {
        case spinStartLoaded, spinStartEmpty, spinLoaded, spinEmpty, spinEnd
        case step, seek2ms, seek6ms, seek12ms, seek20ms

        /// MAME's name for the recording, after its drive type ("35_").
        public var fileName: String {
            switch self {
            case .spinStartLoaded: "spin_start_loaded"
            case .spinStartEmpty: "spin_start_empty"
            case .spinLoaded: "spin_loaded"
            case .spinEmpty: "spin_empty"
            case .spinEnd: "spin_end"
            case .step: "step_1_1"
            case .seek2ms: "seek_2ms"
            case .seek6ms: "seek_6ms"
            case .seek12ms: "seek_12ms"
            case .seek20ms: "seek_20ms"
            }
        }
    }

    public let rate: Double
    let samples: [[Float]]

    /// `samples` has one array for each of `Sound`'s cases, in order.
    public init(rate: Double, samples: [[Float]]) {
        precondition(samples.count == Sound.allCases.count, "one sample for each sound")
        self.rate = rate
        self.samples = samples
    }

    subscript(sound: Sound) -> [Float] { samples[sound.rawValue] }

    /// MAME's 3.5" drive recordings ("35_spin_loaded.wav" and so on) from a
    /// folder; nil if any is missing or unreadable.
    public static func load(folder: String) -> DiscDriveSounds? {
        var rate = 0.0
        var samples: [[Float]] = []
        for sound in Sound.allCases {
            guard let data = FileManager.default.contents(atPath: folder + "/35_\(sound.fileName).wav"),
                  let wav = decodeWAV([UInt8](data)), rate == 0 || wav.rate == rate else { return nil }
            rate = wav.rate
            samples.append(wav.samples)
        }
        return DiscDriveSounds(rate: rate, samples: samples)
    }

    /// A 16-bit PCM WAV file's first channel and rate.
    public static func decodeWAV(_ bytes: [UInt8]) -> (rate: Double, samples: [Float])? {
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
            return nil
        }
        var rate = 0, channels = 0, bits = 0
        var at = 12
        while at + 8 <= bytes.count {
            let size = u32(at + 4)
            let body = at + 8
            guard body + size <= bytes.count else { return nil }
            if bytes[at..<at + 4].elementsEqual("fmt ".utf8), size >= 16 {
                guard u16(body) == 1 else { return nil }  // PCM
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if bytes[at..<at + 4].elementsEqual("data".utf8) {
                guard bits == 16, channels > 0, rate > 0 else { return nil }
                let frame = 2 * channels
                let samples = stride(from: body, to: body + size - frame + 1, by: frame).map {
                    Float(Int16(bitPattern: UInt16(u16($0)))) / 32768
                }
                return (Double(rate), samples)
            }
            at = body + size + (size & 1)
        }
        return nil
    }
}

/// What a floppy controller tells the drives' noises.
public enum DiscDriveEvent: Sendable, Equatable {
    case startSpinning, stopSpinning
    /// The head starts moving `steps` tracks, a step every `stepMs`.
    case seekStart(steps: Int, stepMs: Int)
    /// The head's stopped.
    case seekEnd
}

/// One drive's noises.
struct DiscDriveNoise {
    /// A sample playing from `position` (in the sample's frames), until
    /// `end`.
    struct Voice {
        var sound: DiscDriveSounds.Sound
        var position: Double = 0
        var end: Double = .infinity
    }

    var spin: Voice?
    /// A step or a seek.
    var head: Voice?

    var isQuiet: Bool { spin == nil && head == nil }

    mutating func event(_ event: DiscDriveEvent, hasDisc: Bool, sounds: DiscDriveSounds) {
        switch event {
        case .startSpinning:
            spin = Voice(sound: hasDisc ? .spinStartLoaded : .spinStartEmpty)
        case .stopSpinning:
            if spin != nil { spin = Voice(sound: .spinEnd) }
        case .seekStart(let steps, let stepMs):
            let steps = abs(steps)
            guard steps > 0 else { return }
            if steps == 1 {
                head = Voice(sound: .step)
                return
            }
            // b2's choice of sample for the step rate.
            let sound: DiscDriveSounds.Sound = stepMs >= 17 ? .seek20ms : stepMs >= 10 ? .seek12ms : stepMs >= 4 ? .seek6ms : .seek2ms
            let length = Double(sounds[sound].count)
            head = Voice(sound: sound, end: min(length, Double(steps * stepMs) / 1000 * sounds.rate))
        case .seekEnd:
            // The head's stopped, perhaps short of where it was going.
            if var seek = head, seek.sound != .step {
                seek.end = min(seek.end, seek.position)
                head = seek
            }
        }
    }

    /// The next output sample: `step` frames of the samples' own rate.
    mutating func next(_ sounds: DiscDriveSounds, step: Double) -> Float {
        var level: Float = 0
        if var voice = spin {
            let samples = sounds[voice.sound]
            level += samples[min(Int(voice.position), samples.count - 1)]
            voice.position += step
            if voice.position >= Double(samples.count) {
                switch voice.sound {
                case .spinStartLoaded, .spinLoaded: voice = Voice(sound: .spinLoaded, position: voice.position - Double(samples.count))
                case .spinStartEmpty, .spinEmpty: voice = Voice(sound: .spinEmpty, position: voice.position - Double(samples.count))
                default: spin = nil
                }
            }
            if spin != nil { spin = voice }
        }
        if var voice = head {
            let samples = sounds[voice.sound]
            level += samples[min(Int(voice.position), samples.count - 1)]
            voice.position += step
            head = voice.position >= min(voice.end, Double(samples.count)) ? nil : voice
        }
        return level
    }
}

/// The four floppy drives' noises together, mixed into VIDC's sound.
final class DiscDriveNoises {
    var sounds: DiscDriveSounds? { didSet { drives = Array(repeating: DiscDriveNoise(), count: 4) } }
    private var drives = Array(repeating: DiscDriveNoise(), count: 4)
    // As MacBeeb has them: the recordings are quiet (the motor at about
    // 0.003 of full scale), a seek's peaks then about half of it.
    static let gain: Float = 4

    var isQuiet: Bool { sounds == nil || drives.allSatisfy(\.isQuiet) }

    func event(drive: Int, _ event: DiscDriveEvent, hasDisc: Bool) {
        guard let sounds, drives.indices.contains(drive) else { return }
        drives[drive].event(event, hasDisc: hasDisc, sounds: sounds)
    }

    /// The next sample, at `rate` samples a second.
    func next(rate: Double) -> Float {
        guard let sounds, !isQuiet else { return 0 }
        let step = sounds.rate / rate
        var level: Float = 0
        for i in drives.indices where !drives[i].isQuiet { level += drives[i].next(sounds, step: step) }
        return level * Self.gain
    }
}
