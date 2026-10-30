import XCTest
@testable import ArchimedesCore

/// The floppy drives' noises: MAME's recordings load, and a catalogue of a
/// floppy is heard (the motor and the head) on both kinds of controller.
final class DiscDriveNoiseTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Apps/MacArch/Resources/DriveSounds").standardized.path

    final class Collector: AudioSink {
        var energy: Double = 0
        var count = 0
        func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
            energy += Double(abs(left) + abs(right)) * Double(count)
            self.count += count
        }
    }

    func testTheRecordingsLoad() throws {
        let sounds = try XCTUnwrap(DiscDriveSounds.load(folder: Self.folder))
        XCTAssertGreaterThan(sounds.rate, 0)
        for sound in DiscDriveSounds.Sound.allCases { XCTAssertFalse(sounds[sound].isEmpty, sound.fileName) }
    }

    func testCataloguingAFloppyIsHeard() throws {
        let sounds = try XCTUnwrap(DiscDriveSounds.load(folder: Self.folder))
        let disc = ArcLibreTests.folder.appendingPathComponent("arclibre-0.9.1-2mb-extras.adf").path
        for model in [MachineModel.a3000, .a5000] {
            var heard: [Double] = []
            for on in [false, true] {
                var c = MachineConfiguration(model: model)
                c.romPaths = [ArcLibreTests.path]
                c.cpu = model.defaultCPU
                c.powerOnKeys = [0x34]
                let m = try Machine(configuration: c)
                m.discDriveSounds = on ? sounds : nil
                m.insertFloppy(try FloppyImage.open(path: disc))
                m.powerOn()
                m.run(seconds: 25)
                let collector = Collector()
                m.vidc.audioSink = collector
                m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12: the command line
                m.run(seconds: 0.5)
                m.scheduleTyping("*CAT :0\r", startingAt: m.nominalTicks, intervalMs: 25)
                m.run(seconds: 4)
                XCTAssertGreaterThan(collector.count, 0, "\(model.rawValue): no sound at all")
                heard.append(collector.energy)
            }
            XCTAssertGreaterThan(heard[1], heard[0] + 100, "\(model.rawValue): the drive isn't heard (\(heard))")
        }
    }
}
