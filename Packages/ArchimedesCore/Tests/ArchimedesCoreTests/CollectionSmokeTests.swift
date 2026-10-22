import Foundation
import XCTest
@testable import ArchimedesCore

/// Smoke tests for the wider collection (opt-in, like GameSmokeTests):
///     MACARCH_GAME_TESTS=1 swift test -c release --filter CollectionSmokeTests
/// Each title is started from the desktop with *Filer_Run, then checked for
/// a live, healthy picture. Recipes and findings are in docs/compatibility.md.
final class CollectionSmokeTests: XCTestCase {
    typealias Script = GameSmokeTests.Script

    func script(_ name: String, disc: String) throws -> Script {
        try GameSmokeTests().script(name, disc: disc)
    }

    /// Runs an application on the floppy as the Filer would (F12, then
    /// Return on an empty line to go back to the desktop).
    func launch(_ s: Script, _ app: String, openDirectory: Bool = false) {
        s.press("f12")
        if openDirectory { s.type("Filer_OpenDir ADFS::0.$\n") }
        s.type("Filer_Run ADFS::0.$.\(app)\n\n")
    }

    /// Distinct colours in the frame: a real picture has more than a few.
    func colours(_ f: VideoFrame) -> Int { Set(f.pixels).count }

    func changed(_ a: VideoFrame, _ b: VideoFrame) -> Int {
        guard a.width == b.width, a.height == b.height else { return a.pixels.count }
        return zip(a.pixels, b.pixels).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    }

    /// Zarch (Play It Again Sam 2, disc 1): the menu, the demo prompt, then
    /// the landscape with the lander.
    func testZarch() throws {
        let s = try script("zarch", disc: "Play it Again Sam 2 (1993)(Superior)(Disk 1 of 2).adf")
        launch(s, "!Superior")
        s.wait(25)
        s.capture("1-menu")
        s.press("1")
        s.wait(25)
        s.capture("2-demo-prompt")
        s.press("space")
        s.wait(8)
        let a = s.m.currentFrame
        s.wait(1)
        s.capture("3-landscape")
        XCTAssertGreaterThan(colours(s.m.currentFrame), 12, "the landscape is drawn")
        XCTAssertGreaterThan(changed(a, s.m.currentFrame), 100, "the scene is live")
        s.assertHealthy()
    }

    /// Paradroid 2000: title, Return to play, the deck.
    func testParadroid2000() throws {
        let s = try script("paradroid2000", disc: "Paradroid 2000.adf")
        launch(s, "!ParaDroid")
        s.wait(45)
        s.capture("1-title")
        let title = s.m.currentFrame
        s.press("return")
        s.wait(10)
        s.capture("2-deck")
        XCTAssertGreaterThan(changed(title, s.m.currentFrame), s.m.currentFrame.pixels.count / 3, "left the title for the deck")
        XCTAssertGreaterThan(colours(s.m.currentFrame), 8)
        s.assertHealthy()
    }

    /// Speedball 2 (an image one track short): the Bitmap Brothers intro.
    func testSpeedball2() throws {
        let s = try script("speedball2", disc: "Speedball 2 - Brutal Deluxe (1992)(Krisalis).adf")
        launch(s, "!SpeedBall")
        s.wait(70)
        s.capture("1-intro")
        XCTAssertGreaterThan(colours(s.m.currentFrame), 12, "the arena picture is drawn")
        s.assertHealthy()
    }

    /// Pacmania (ADFS D, one track short): the attract demo plays.
    func testPacmania() throws {
        let s = try script("pacmania", disc: "Pacmania (1991)(Krisalis).adf")
        launch(s, "!PacMania")
        s.wait(45)
        let a = s.m.currentFrame
        s.wait(1)
        s.capture("1-demo")
        XCTAssertGreaterThan(colours(s.m.currentFrame), 8)
        XCTAssertGreaterThan(changed(a, s.m.currentFrame), 100, "the demo moves")
        s.assertHealthy()
    }

    /// UIM from the HFE (raw MFM tracks) image.
    func testUIMFromHFE() throws {
        let s = try script("uim-hfe", disc: "UIM (1989)(4th Dimension).hfe")
        launch(s, "!UIM")
        s.wait(60)
        s.capture("1-title")
        XCTAssertEqual(s.m.vidc.bitsPerPixel, 8)
        XCTAssertGreaterThan(colours(s.m.currentFrame), 12, "the cockpit is drawn")
        s.assertHealthy()
    }

    /// Sim City (Krisalis, ADFS E, one track short): needs its !System seen
    /// first (the directory opened), then the New City dialog starts a map.
    func testSimCity() throws {
        let s = try script("simcity", disc: "Sim City (1993)(Krisalis Software).adf")
        launch(s, "!SimCity", openDirectory: true)
        s.wait(70)
        s.capture("1-iconbar")
        XCTAssertFalse(s.m.recentText.contains("System resources cannot be found"))
        s.assertHealthy()
    }

    /// Sim City 2000 (A5000 version) came as files: a hard disc is built
    /// from the archive, on a 4 MB A5000 with a multisync monitor (the game
    /// uses 640 x 480), and a saved city is loaded from it.
    func testSimCity2000FromZip() throws {
        guard ProcessInfo.processInfo.environment["MACARCH_GAME_TESTS"] != nil else { throw XCTSkip("set MACARCH_GAME_TESTS=1") }
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let zip = GameSmokeTests.root.appendingPathComponent("discimages/Sim City 2000 (1993) (Krisalis) (A5000 Version).zip").path
        guard let bytes = FileManager.default.contents(atPath: zip) else { throw XCTSkip("Sim City 2000 archive not present") }
        let hd = NSTemporaryDirectory() + "macarch-sc2k-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: hd) }
        try ADFSHardDiscBuilder.create(path: hd, geometry: HardDiscGeometry.idePresets[0].geometry, name: "HardDisc4",
                                       items: try ADFSHardDiscBuilder.items(fromZip: [UInt8](bytes)))
        var c = MachineConfiguration(model: .a5000)
        c.romPaths = [rom]
        c.ramKB = 4096
        c.monitorType = .multisync
        c.hardDiscs = [hd]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        let s = Script(m, name: "simcity2000")
        s.waitUntil("desktop", timeout: 40) { m.recentText.contains("Apps") }
        s.wait(1)
        XCTAssertEqual(m.currentFrame.width, 640, "the multisync desktop is 640 x 480")
        s.press("f12")
        s.type("Filer_Run ADFS::4.$.!SC2000\n\n")
        s.wait(40)
        s.capture("1-title")
        // Click away the title and the owner notice with the pointer in the
        // sky (top right), where a click on the menu can't land on a button.
        s.pointTip(at: 600, 30, corner: true)
        s.click(); s.wait(10)
        s.click(); s.wait(8)
        s.capture("2-menu")
        s.pointTip(at: 318, 175, corner: true); s.click()        // Load Saved City
        s.wait(8)
        s.capture("3-load")
        s.pointTip(at: 222, 167, corner: true); s.click()        // GOODCITY
        s.wait(2)
        s.pointTip(at: 239, 376, corner: true); s.click()        // Load
        s.wait(30)
        s.capture("4-city")
        // Sim City 2000 draws its own pointer, whose image starts at its tip.
        XCTAssertGreaterThan(colours(m.currentFrame), 40, "the city is drawn")
        s.assertHealthy()
    }
}
