import Foundation
import XCTest
@testable import ArchimedesCore

// The Distributed Mandelbrot demo, run end to end through RISC OS's own
// software: Acorn's Level 4 File Server (from the user's Release 3 disc,
// discimages/release3/Level 4.adf, not in the repository) with the demo's
// programs, workers that boot from the network into Worker, and a
// coordinator that logs on as GUEST and types Mandel. Everything between
// the machines goes over the emulated Econet; the coordinator's screen is
// compared with the reference, pixel for pixel.

/// A Mandelbrot network: the server, the coordinator and the workers.
final class MandelbrotRig {
    let net = EconetNetwork()
    let rom: String
    let folder: URL
    let server: Machine
    var coordinator: Machine!
    var workers: [Machine] = []
    let trace = EconetTrace(capacity: 200_000)

    static let coordinatorStation = 1

    init(disc: [UInt8], rom: String) throws {
        self.rom = rom
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mandelbrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hd = folder.appendingPathComponent("server.hdf").path
        try MandelbrotNetwork.createFileServerDisc(path: hd, geometry: HardDiscGeometry(cylinders: 615, heads: 4), fromLevel4Disc: disc)
        var s = MachineConfiguration(model: .a440)
        s.romPaths = [rom]
        s.ramKB = 4096
        s.powerOnKeys = [0x34]
        s.econetStation = MandelbrotNetwork.fileServer
        s.hardDiscs = [hd]
        s.cmosSettings = Level4.cmosSettings(ramKB: s.ramKB)
        server = try Machine(configuration: s)
        net.add(server)
        net.line.observer = { [trace] in trace.observe($0) }
        net.useThreads(ProcessInfo.processInfo.environment["MANDEL_THREADS"].flatMap { Int($0) } ?? min(4, LockstepWorkers.maxThreads))
    }

    deinit {
        net.useThreads(1)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A worker: an A3000 that boots from the network.
    @discardableResult
    func addWorker(_ station: Int) throws -> Machine {
        var c = MachineConfiguration()
        c.romPaths = [rom]
        c.powerOnKeys = [0x34]
        c.econetStation = station
        c.cmosSettings = MandelbrotNetwork.workerCMOSSettings()
        let m = try Machine(configuration: c)
        net.add(m)
        workers.append(m)
        return m
    }

    /// The coordinator: the Guide, an A5000 that boots from its own hard
    /// disc, logs on as GUEST and leaves a * prompt.
    func addCoordinator() throws {
        let hd = folder.appendingPathComponent("guide.hdf").path
        try MandelbrotNetwork.createGuideDisc(path: hd, geometry: HardDiscGeometry.idePresets[0].geometry)
        var c = MachineConfiguration(model: .a5000)
        c.romPaths = [rom]
        c.powerOnKeys = [0x34]
        c.econetStation = Self.coordinatorStation
        c.hardDiscs = [hd]
        c.cmosSettings = MandelbrotNetwork.guideCMOSSettings()
        coordinator = try Machine(configuration: c)
        net.add(coordinator)
    }

    func run(seconds: Double) { net.run(seconds: seconds) }

    /// Runs until `done`, checking every half second; false if it never was.
    @discardableResult
    func run(until done: () -> Bool, seconds: Double) -> Bool {
        var left = seconds
        while left > 0 {
            if done() { return true }
            net.run(seconds: 0.5)
            left -= 0.5
        }
        return done()
    }

    func type(_ m: Machine, _ text: String) {
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 30)
        while m.pendingInputEvents > 0 { net.run(seconds: 0.1) }
    }

    func press(_ m: Machine, key: UInt8) {
        m.keyDown(key)
        net.run(seconds: 0.1)
        m.keyUp(key)
    }

    func screen(_ m: Machine) -> String { m.screenText.joined(separator: "\n") }

    /// What a worker's screen says it's done.
    func tilesDone(_ m: Machine) -> Int {
        screen(m).split(separator: "\n").first { $0.contains("Tiles done:") }
            .flatMap { line in Int(line.split(separator: ":")[1].split(separator: " ").first ?? "") } ?? 0
    }

    /// A machine's MODE 12 picture, a colour a pixel: the 240 rows below
    /// the status lines, read from the screen memory the display shows.
    func picture(_ m: Machine) -> [UInt8] {
        let memc = m.memc
        var bytes: [UInt8] = []
        bytes.reserveCapacity(320 * 256)
        var p = memc.vinit
        for _ in 0 ..< 320 * 256 / 16 {
            for i in 0 ..< 16 { bytes.append(memc.debugRead(p &+ UInt32(i), space: .physical) ?? 0) }
            p = p == memc.vend ? memc.vstart : p &+ 16
        }
        let top = MandelbrotProtocol.imageTop
        return (top ..< top + MandelbrotProtocol.imageHeight).flatMap { y in
            (0 ..< MandelbrotProtocol.imageWidth).map { x in (bytes[y * 320 + x / 2] >> (x % 2 * 4)) & 0xF }
        }
    }

    func capture(_ m: Machine, _ name: String) {
        guard let out = ProcessInfo.processInfo.environment["MACARCH_MANDELBROT_CAPTURE"] else { return }
        let f = m.currentFrame
        try? PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY).write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        try? screen(m).write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}

final class MandelbrotNetworkTests: XCTestCase {
    static let picture = MandelbrotReference.colours()

    func rig(workers: [Int]) throws -> MandelbrotRig {
        guard let disc = Level4Tests.disc else { throw XCTSkip("discimages/release3/Level 4.adf not present") }
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("ROM not present in ./roms/riscos3_11") }
        let rig = try MandelbrotRig(disc: disc, rom: rom)
        // The server's up first, as in a classroom.
        rig.run(seconds: 35)
        for station in workers { try rig.addWorker(station) }
        try rig.addCoordinator()
        return rig
    }

    /// The Guide's booted, logged on: the teacher types Mandel.
    func startMandel(_ rig: MandelbrotRig, _ command: String = "Mandel") {
        XCTAssertTrue(rig.run(until: { rig.screen(rig.coordinator).contains("Mandel Stop") }, seconds: 30), rig.screen(rig.coordinator))
        rig.type(rig.coordinator, command + "\n")
    }

    /// Workers boot from the network into Worker; Mandel finds them,
    /// renders, and the picture is the reference's. A key gives the summary.
    func testRender() throws {
        let rig = try rig(workers: [2, 3])
        let booted = rig.run(until: { rig.workers.allSatisfy { rig.screen($0).contains("waiting for a coordinator") } }, seconds: 60)
        for (i, w) in rig.workers.enumerated() { rig.capture(w, "worker\(i)-booted") }
        rig.capture(rig.coordinator, "coordinator-booted")
        XCTAssertTrue(booted, rig.workers.map(rig.screen).joined(separator: "\n----\n"))
        guard booted else { return }

        startMandel(rig)
        let done = rig.run(until: { rig.screen(rig.coordinator).contains("Complete: 300 tiles") }, seconds: 240)
        rig.capture(rig.coordinator, "coordinator-done")
        for (i, w) in rig.workers.enumerated() { rig.capture(w, "worker\(i)-done") }
        XCTAssertTrue(done, rig.screen(rig.coordinator) + "\n----\n" + rig.workers.map(rig.screen).joined(separator: "\n----\n"))
        guard done else { return }
        XCTAssertEqual(rig.picture(rig.coordinator), Self.picture)
        // Each worker drew its own tiles: every pixel it has is the reference's.
        for w in rig.workers {
            let mine = rig.picture(w)
            XCTAssertTrue(zip(mine, Self.picture).allSatisfy { $0 == 0 || $0 == $1 })
        }
        // Both did some; between them, all 300.
        XCTAssertTrue(rig.run(until: { rig.workers.allSatisfy { rig.screen($0).contains("Picture done") } }, seconds: 10))
        let done2 = rig.workers.map(rig.tilesDone)
        XCTAssertTrue(done2.allSatisfy { $0 > 0 } && done2.reduce(0, +) == 300, "\(done2)")

        // The observer, from the trace alone, has the same picture.
        var observer = MandelbrotObserver()
        observer.observe(rig.trace.frames)
        XCTAssertEqual(observer.tilesCompleted, 300)
        XCTAssertEqual(observer.coordinator, UInt8(MandelbrotRig.coordinatorStation))
        XCTAssertTrue(observer.completeSeen)
        XCTAssertEqual(observer.image, MandelbrotReference.image())
        XCTAssertEqual(observer.malformed, 0)

        rig.type(rig.coordinator, " ")
        XCTAssertTrue(rig.run(until: { rig.screen(rig.coordinator).contains("300 of 300 tiles") }, seconds: 10), rig.screen(rig.coordinator))
        XCTAssertTrue(rig.screen(rig.coordinator).contains("from 2 workers"), rig.screen(rig.coordinator))

        // Mandel Stop: the workers go back to waiting, as at boot.
        rig.type(rig.coordinator, "Mandel Stop\n")
        XCTAssertTrue(rig.run(until: { rig.screen(rig.coordinator).contains("2 stopped.") }, seconds: 30), rig.screen(rig.coordinator))
        XCTAssertTrue(rig.workers.allSatisfy { rig.screen($0).contains("waiting for a coordinator") && rig.screen($0).contains("Waiting") },
                      rig.workers.map(rig.screen).joined(separator: "\n----\n"))
    }

    /// A worker switched off part way: its tile goes to the other after the
    /// timeout. Switched on again, it boots back into Worker; Mandel finds
    /// it (DISCOVER, START) and it joins in. The picture's still right.
    func testWorkerLostAndRejoining() throws {
        let rig = try rig(workers: [2, 3])
        XCTAssertTrue(rig.run(until: { rig.workers.allSatisfy { rig.screen($0).contains("waiting for a coordinator") } }, seconds: 60))
        startMandel(rig)
        XCTAssertTrue(rig.run(until: { rig.tilesDone(rig.workers[1]) >= 20 }, seconds: 120), rig.screen(rig.workers[1]))
        rig.net.remove(rig.workers[1])
        rig.workers.remove(at: 1)
        rig.run(seconds: 2)
        let again = try rig.addWorker(3)
        let done = rig.run(until: { rig.screen(rig.coordinator).contains("Complete: 300 tiles") }, seconds: 300)
        rig.capture(rig.coordinator, "rejoin-coordinator")
        rig.capture(again, "rejoin-worker")
        XCTAssertTrue(done, rig.screen(rig.coordinator) + "\n----\n" + rig.workers.map(rig.screen).joined(separator: "\n----\n"))
        XCTAssertEqual(rig.picture(rig.coordinator), Self.picture)
        // It was found again, and did some.
        XCTAssertTrue(rig.screen(again).contains("for station 1"), rig.screen(again))
        XCTAssertGreaterThan(rig.tilesDone(again), 0, rig.screen(again))
    }
}

/// How long a render takes, in emulated time, by the number of workers
/// (MANDELBROT_BENCH=1).
final class MandelbrotBenchmark: XCTestCase {
    func testRenderTimes() throws {
        guard ProcessInfo.processInfo.environment["MANDELBROT_BENCH"] != nil else { throw XCTSkip("MANDELBROT_BENCH=1 to run") }
        for count in [1, 2, 4, 8] {
            let tests = MandelbrotNetworkTests()
            let rig = try tests.rig(workers: Array(2 ..< 2 + count))
            rig.run(until: { rig.workers.allSatisfy { rig.screen($0).contains("waiting for a coordinator") } }, seconds: 90)
            let wall = Date()
            tests.startMandel(rig)
            XCTAssertTrue(rig.run(until: { rig.screen(rig.coordinator).contains("Complete: 300 tiles") }, seconds: 900))
            let line = rig.screen(rig.coordinator).split(separator: "\n").first { $0.contains("Complete") } ?? ""
            print("BENCH \(count) workers: \(line.trimmingCharacters(in: .whitespaces)) (\(Int(Date().timeIntervalSince(wall)))s wall)")
        }
    }
}
