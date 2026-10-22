import Foundation
import XCTest
@testable import ArchimedesCore

/// Scripted smoke tests for the four acceptance games. Each boots RISC OS
/// 3.11 from a CMOS reset, drives the game to real gameplay with scripted
/// input, checks game-specific markers, and writes a screenshot, the frame
/// hash and an event log to tests/reports/games/.
///
/// They need the user's ROM and disc images (skipped when absent) and run
/// 100+ s of guest time each, so they are opt-in:
///     MACARCH_GAME_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter GameSmokeTests
final class GameSmokeTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
    static let reports = root.appendingPathComponent("tests/reports/games")

    /// Drives one machine and keeps a log of what it did.
    final class Script {
        let m: Machine
        let name: String
        private(set) var log: [String] = []

        init(_ m: Machine, name: String) { self.m = m; self.name = name }

        func note(_ s: String) { log.append(String(format: "%7.2f s  ", m.seconds) + s) }

        func wait(_ seconds: Double) { m.run(seconds: seconds) }

        /// Runs until `condition` holds (checked every 0.1 s) or `timeout`.
        @discardableResult
        func waitUntil(_ what: String, timeout: Double, _ condition: () -> Bool) -> Bool {
            let deadline = m.nominalTicks + UInt64(timeout * Double(MasterClock.ticksPerSecond))
            while !condition() {
                if m.nominalTicks >= deadline { note("timed out waiting for \(what)"); return false }
                m.run(seconds: 0.1)
            }
            note("reached: \(what)")
            return true
        }

        func press(_ key: String, ms: Int = 120) {
            guard let code = ArcKey.names[key] else { return XCTFail("no key \(key)") }
            note("press \(key)")
            m.keyDown(code); wait(Double(ms) / 1000); m.keyUp(code); wait(0.1)
        }

        func type(_ text: String) {
            note("type \(text.debugDescription)")
            m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 60)
            wait(Double(text.count) * 0.12 + 0.5)
        }

        func click(_ button: String = "select", double: Bool = false) {
            for _ in 0..<(double ? 2 : 1) {
                m.keyDown(ArcKey.names[button]!); wait(0.08); m.keyUp(ArcKey.names[button]!); wait(0.12)
            }
            note((double ? "double-click " : "click ") + button)
        }

        /// Relative mouse movement in counts, delivered in small steps.
        func nudge(_ dx: Int, _ dy: Int) {
            var x = dx, y = dy
            while x != 0 || y != 0 {
                let sx = max(-20, min(20, x)), sy = max(-20, min(20, y))
                m.mouseMove(dx: sx, dy: sy); wait(0.02)
                x -= sx; y -= sy
            }
        }

        /// Pins the pointer to the bottom-left corner, then moves by a fixed
        /// amount: deterministic wherever it started (for games that draw
        /// their own pointer).
        /// RISC OS 2 moves the pointer about a third as far per mouse count
        /// as RISC OS 3 does with its default CMOS; game moves are written
        /// in RISC OS 3 counts and scaled by this.
        var moveScale = 1.0

        /// A relative move in RISC OS 3 counts (scaled for the ROM).
        func move(_ dx: Int, _ dy: Int) {
            nudge(Int((Double(dx) * moveScale).rounded()), Int((Double(dy) * moveScale).rounded()))
        }

        /// (Raw counts: games scale the mouse their own way.)
        func pointerFromCorner(_ dx: Int, _ dy: Int) {
            nudge(-4000, -4000)
            nudge(dx, dy)
            note("pointer from corner +\(dx),+\(dy)")
        }

        /// Moves the desktop pointer to a frame pixel, steering by the VIDC
        /// hardware cursor position.
        func point(at x: Int, _ y: Int) {
            for _ in 0..<12 {
                let p = m.vidc.pointerPosition
                let ex = x - p.x, ey = y - p.y
                if abs(ex) <= 1 && abs(ey) <= 1 { break }
                // About 1 count per pixel across, 2 counts per frame line (+y up).
                nudge(ex, -ey * 2)
                wait(0.1)
            }
            let p = m.vidc.pointerPosition
            note("pointer at \(p.x),\(p.y) (wanted \(x),\(y))")
            XCTAssertLessThanOrEqual(abs(p.x - x) + abs(p.y - y), 4, "pointer reached \(x),\(y)", file: #filePath, line: #line)
        }

        /// Like `point(at:)`, but steering the pointer's tip (its hot spot,
        /// or with `corner` its image's top-left) on any screen shape.
        func pointTip(at x: Int, _ y: Int, corner: Bool = false) {
            for _ in 0..<40 {
                let p = corner ? m.vidc.pointerPosition : m.vidc.pointerHotspot
                let ex = x - p.x, ey = y - p.y
                if abs(ex) <= 1 && abs(ey) <= 1 { break }
                // About one count per pixel across; down, one per OS unit
                // (two per line on a TV-rate screen, one on a square one).
                nudge(max(-60, min(60, ex)), max(-60, min(60, -ey * m.currentFrame.scaleY)))
                wait(0.05)
            }
            let p = corner ? m.vidc.pointerPosition : m.vidc.pointerHotspot
            note("pointer tip at \(p.x),\(p.y) (wanted \(x),\(y))")
            XCTAssertLessThanOrEqual(abs(p.x - x) + abs(p.y - y), 4, "pointer reached \(x),\(y)", file: #filePath, line: #line)
        }

        var frameChecksum: String { String(format: "%016llX", m.currentFrame.checksum) }

        /// Writes the current frame and the log so far.
        func capture(_ step: String) {
            let dir = GameSmokeTests.reports
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = m.currentFrame
            try? PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY).write(to: dir.appendingPathComponent("\(name)-\(step).png"))
            note("capture \(step): frame \(f.frameNumber) \(f.width)x\(f.height) checksum \(frameChecksum)")
            try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8)
        }

        /// No guest crash reported on screen or in the OS text stream.
        func assertHealthy(file: StaticString = #filePath, line: UInt = #line) {
            let text = m.recentText
            for bad in ["Internal error", "Abort on", "Undefined instruction"] {
                XCTAssertFalse(text.contains(bad), "\(name): guest reported \(bad)", file: file, line: line)
            }
            XCTAssertEqual(m.cpu.exceptionCounts[5], 0, "\(name): no address exceptions", file: file, line: line)
        }
    }

    /// The ROM folder for a profile ("riscos3_11" or "riscos2_00"), if present.
    static func romDir(_ profile: String) -> String? {
        let p = root.appendingPathComponent("roms/" + profile).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func script(_ name: String, disc: String, rom profile: String = "riscos3_11", model: MachineModel = .a3000) throws -> Script {
        guard ProcessInfo.processInfo.environment["MACARCH_GAME_TESTS"] != nil else {
            throw XCTSkip("set MACARCH_GAME_TESTS=1 to run the game smoke tests")
        }
        guard let rom = Self.romDir(profile) else { throw XCTSkip("ROM not present in ./roms/\(profile)") }
        let discPath = Self.root.appendingPathComponent("discimages/" + disc).path
        guard FileManager.default.fileExists(atPath: discPath) else { throw XCTSkip("\(disc) not present") }
        var c = MachineConfiguration(model: model)
        c.romPaths = [rom]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        let image = try FloppyImage.open(path: discPath)
        m.insertFloppy(image)
        m.powerOn()
        let s = Script(m, name: name)
        if profile == "riscos2_00" { s.moveScale = 3 }
        s.note("\(m.rom.versionString), \(model.displayName) (\(c.cpu.rawValue)), disc \(disc) sha256 \(image.sha256)")
        // RISC OS 3 adds an Apps icon last; RISC OS 2 has none, but prints ":0" for the drive icon.
        s.waitUntil("desktop", timeout: 40) { m.recentText.contains(profile == "riscos2_00" ? "D:0" : "Apps") }
        if profile == "riscos2_00" { s.wait(3) }
        s.wait(1)
        return s
    }

    /// Changed pixels between two frames of the same size (0 if sizes differ).
    func changedPixels(_ a: VideoFrame, _ b: VideoFrame) -> Int {
        guard a.width == b.width, a.height == b.height else { return a.pixels.count }
        return zip(a.pixels, b.pixels).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    }

    // MARK: Games

    func testRepton3() throws { try runRepton3(rom: "riscos3_11") }
    func testRepton3OnRISCOS2() throws { try runRepton3(rom: "riscos2_00") }
    /// The A5000: ARM3, and the 82C711's 765 floppy controller.
    func testRepton3OnA5000() throws { try runRepton3(rom: "riscos3_11", model: .a5000) }

    func runRepton3(rom: String, model: MachineModel = .a3000) throws {
        let s = try script("repton3" + (rom == "riscos3_11" ? "" : "-" + rom) + (model == .a3000 ? "" : "-" + model.rawValue.lowercased()),
                           disc: "adfs_Repton_3.adf", rom: rom, model: model)
        s.press("f12")
        s.type("DIR ADFS::0.$\n!RISC_OS\n")
        s.wait(30)
        s.capture("1-title")
        s.press("1")
        s.wait(9)
        s.capture("2-menu")
        s.press("space")
        s.wait(8)
        s.capture("3-level")
        let before = s.m.currentFrame
        // Walk Repton right (X) for a second: the screen must change.
        s.press("x", ms: 1000)
        s.wait(0.5)
        s.capture("4-moved")
        XCTAssertGreaterThan(changedPixels(before, s.m.currentFrame), 500, "Repton moves")
        s.assertHealthy()
    }

    func testElite() throws { try runElite(rom: "riscos3_11") }
    func testEliteOnRISCOS2() throws {
        // Not an emulation limit: the 1995 cover disc runs its own ArcFS
        // Filer extension, which fails under RISC OS 2 ("Syntax:
        // *Filer_OpenDir <full dirname>") before Elite can be opened.
        throw XCTSkip("the Acorn User Aug 95 disc needs RISC OS 3 (its ArcFS Filer)")
    }

    func testEliteOnA5000() throws { try runElite(rom: "riscos3_11", model: .a5000) }

    func runElite(rom: String, model: MachineModel = .a3000) throws {
        let s = try script("elite" + (rom == "riscos3_11" ? "" : "-" + rom) + (model == .a3000 ? "" : "-" + model.rawValue.lowercased()),
                           disc: "adfs_AcornUser_199508.adf", rom: rom, model: model)
        let m = s.m
        s.point(at: 95, 256); s.click()                  // :0 on the icon bar
        s.wait(4)
        s.point(at: 213, 28); s.click(double: true)      // !AUélite
        s.wait(5)
        s.point(at: 275, 38); s.click(double: true)      // élite directory
        s.wait(5)
        s.point(at: 245, 38); s.click(double: true)      // !élite
        s.wait(47)                                       // loads from floppy
        s.point(at: 584, 256); s.click()                 // Elite's icon-bar icon
        s.wait(10)
        s.capture("1-title")
        s.press("space")
        s.wait(6)
        s.capture("2-commander")
        s.press("f1")
        s.wait(8)
        s.capture("3-launched")
        let sound = m.vidc.soundBytesNonSilent
        s.click()                                        // fire the laser
        s.wait(1)
        s.note("non-silent sound bytes +\(m.vidc.soundBytesNonSilent - sound)")
        XCTAssertGreaterThan(m.vidc.soundBytesNonSilent - sound, 2000, "the laser sounds")
        s.capture("4-fired")
        s.assertHealthy()
    }

    func testLemmings() throws { try runLemmings(rom: "riscos3_11") }
    func testLemmingsOnRISCOS2() throws { try runLemmings(rom: "riscos2_00") }
    func testLemmingsOnA5000() throws { try runLemmings(rom: "riscos3_11", model: .a5000) }

    /// Desktop click targets (pointer coordinates) per ROM: RISC OS 2's
    /// desktop is a different mode and its Filer windows sit elsewhere.
    struct Desk {
        var drive0: (Int, Int)
        var firstIcon: (Int, Int)
        var secondIcon: (Int, Int)
        static func of(_ rom: String) -> Desk {
            rom == "riscos2_00"
                ? Desk(drive0: (40, 257), firstIcon: (183, 67), secondIcon: (278, 65))
                : Desk(drive0: (95, 256), firstIcon: (213, 28), secondIcon: (215, 38))
        }
    }

    func runLemmings(rom: String, model: MachineModel = .a3000) throws {
        let s = try script("lemmings" + (rom == "riscos3_11" ? "" : "-" + rom) + (model == .a3000 ? "" : "-" + model.rawValue.lowercased()),
                           disc: "adfs_Lemmings.adf", rom: rom, model: model)
        let m = s.m
        let desk = Desk.of(rom)
        s.point(at: desk.drive0.0, desk.drive0.1); s.click()
        s.wait(4)
        s.point(at: desk.secondIcon.0, desk.secondIcon.1); s.click(double: true) // !Lemmings
        s.wait(41)
        // The START sign: Lemmings reads the mouse on its own scale.
        if rom == "riscos2_00" { s.pointerFromCorner(62, 50) } else { s.pointerFromCorner(60, 50) }
        s.wait(rom == "riscos2_00" ? 32 : 17)
        s.capture("1-menu")
        let menu = m.currentFrame
        s.click()
        s.wait(30)
        s.capture("2-preview")
        let preview = m.currentFrame
        s.click()
        s.wait(12)
        let a = m.currentFrame
        s.wait(1)
        s.capture("3-level")
        let level = m.currentFrame
        // Each screen is a different picture (the menu animates, so "some
        // pixels changed" is not enough), and the level itself is live.
        let total = level.pixels.count
        XCTAssertGreaterThan(changedPixels(menu, preview), total / 3, "left the menu for the level preview")
        XCTAssertGreaterThan(changedPixels(preview, level), total / 3, "left the preview for the level")
        XCTAssertGreaterThan(changedPixels(a, level), 50, "lemmings move")
        XCTAssertEqual(m.ioc.timerLatches[1], 29952, "panel split timer armed")
        s.assertHealthy()
    }

    func testHoledOut() throws { try runHoledOut(rom: "riscos3_11") }
    func testHoledOutOnRISCOS2() throws { try runHoledOut(rom: "riscos2_00") }

    func testHoledOutOnA5000() throws { try runHoledOut(rom: "riscos3_11", model: .a5000) }

    func runHoledOut(rom: String, model: MachineModel = .a3000) throws {
        let disc = "Holed Out!! (1989) (The Fourth Dimension) F1019900/Discs/Holed Out!! (1989) (The Fourth Dimension) F1019901.jfd"
        let s = try script("holedout" + (rom == "riscos3_11" ? "" : "-" + rom) + (model == .a3000 ? "" : "-" + model.rawValue.lowercased()),
                           disc: disc, rom: rom, model: model)
        let m = s.m
        s.press("f12")
        s.type("/adfs::0.$.!BOOT\n")
        // First run: saves a CMOS backup to the disc, then reboots itself.
        s.waitUntil("Cram written and machine rebooted", timeout: 60) {
            m.fdc.drives[0].disc?.isModified == true && m.recentText.components(separatedBy: "RISC OS 2048K").count >= 3
        }
        s.wait(38)
        s.capture("1-instructions")
        s.move(40, 0)                                   // onto NO (the pointer starts centred)
        s.wait(1.5)
        s.click()
        s.wait(20)
        s.capture("2-title")
        s.click()                                        // past the title
        s.wait(12)
        s.capture("3-course-menu")
        // The course dialog is wider than the instructions one: just inside
        // its left edge is white only once the course question is showing.
        let f = m.currentFrame
        let edge = f.pixels[150 * f.width + 160 * f.width / 832]
        s.note(String(format: "course dialog edge pixel %08X", edge))
        XCTAssertEqual(edge & 0xFFFFFF, 0xFFFFFF, "the course question is on screen")
        s.move(-80, 0)                                  // onto CONE LINKS
        s.wait(1)
        s.click()
        s.wait(25)
        s.capture("4-play-or-preview")
        s.click()                                        // PLAY (the pointer is on it)
        s.wait(20)
        s.capture("5-rules")
        s.move(150, 0)                                  // onto STROKE PLAY
        s.wait(1)
        s.click()
        s.wait(20)
        s.capture("6-players")
        s.move(-90, 0)                                  // onto the "1"
        s.wait(1)
        s.click()
        s.wait(20)
        s.capture("7-name")
        s.type("ARC\n")
        s.wait(20)
        s.capture("8-hand")
        s.click()                                        // LEFT (the pointer is on it)
        s.wait(20)
        s.capture("9-skill")
        s.click()                                        // BEGINNER (the pointer is on it)
        s.wait(20)
        s.capture("10-confirm")
        s.move(-30, 0)                                  // onto YES
        s.wait(1)
        s.click()
        s.wait(30)
        s.capture("11-hole")
        // The club panel (top left) switches to the power meter once a club
        // is chosen: the course is live and takes input.
        let panel = { () -> [UInt32] in
            let f = m.currentFrame
            return (20..<80).flatMap { y in (40..<160).map { f.pixels[y * f.width + $0 * f.width / 416] } }
        }
        let clubs = panel()
        s.click()                                        // 1 WOOD (the pointer is on it)
        s.wait(4)
        s.capture("12-club")
        XCTAssertNotEqual(panel(), clubs, "the club was selected")
        // The Archimedes version is mouse-driven (its own instructions screen):
        // button 2, the middle (Menu) button, accepts the aim and starts the
        // power bar; pressing it again plays the shot.
        let strokes = { () -> [UInt32] in
            let f = m.currentFrame // "STROKES PLAYED : n" in the status panel
            return (72..<80).flatMap { y in (300..<320).map { f.pixels[y * f.width + $0 * f.width / 416] } }
        }
        let before = strokes()
        s.click("menu")
        s.wait(3)
        s.click("menu")
        s.wait(15)
        s.capture("13-shot")
        XCTAssertNotEqual(strokes(), before, "the stroke count changed: the shot was played")
        s.assertHealthy()
    }
}
