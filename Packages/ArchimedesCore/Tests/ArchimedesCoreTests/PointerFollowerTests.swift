import XCTest
@testable import ArchimedesCore

/// The app's "follow the Mac pointer" mouse mode: RISC OS's pointer is
/// steered to a spot on the screen with ordinary mouse counts.
final class PointerFollowerTests: XCTestCase {
    func testThePointerGoesWhereItIsSent() throws {
        var ran = 0
        for rom in ["riscos3_11", "riscos2_00"] {
            guard let dir = GameSmokeTests.romDir(rom) else { continue }
            ran += 1
            var c = MachineConfiguration(model: .a3000)
            c.romPaths = [dir]
            let m = try Machine(configuration: c)
            let follower = PointerFollower()
            m.vidc.frameCompleted = { [unowned m] _ in m.ioc.pumpKeyboard(); follower.frame(m) }
            m.powerOn()
            m.run(seconds: 8)
            XCTAssertFalse(m.vidc.pointerShown, "\(rom): there's no pointer at the * prompt")
            m.scheduleTyping("DESKTOP\r", intervalMs: 40)
            m.run(seconds: 6)
            XCTAssertTrue(m.vidc.pointerShown, "\(rom): the desktop's pointer is on")
            guard let d = m.currentFrame.displayArea else { return XCTFail("\(rom): no display area") }
            // Corners, the middle, and small moves (as a Mac cursor makes).
            let spots = [(d.x + 20, d.y + 20), (d.x + d.width - 30, d.y + d.height - 30), (d.x + d.width / 2, d.y + d.height / 2),
                         (d.x + d.width / 2 + 3, d.y + d.height / 2 - 2), (d.x + 100, d.y + d.height - 10)]
            check(m, follower, spots, "\(rom) desktop")
            // A mode with bigger pixels, where a count moves it less than one.
            follower.target = nil
            m.keyDown(ArcKey.names["f12"]!); m.run(seconds: 0.1); m.keyUp(ArcKey.names["f12"]!); m.run(seconds: 0.5)
            // (Typing comes out lower case: Caps Lock for BASIC's keywords.)
            let caps = ArcKey.names["capslock"]!
            m.keyDown(caps); m.run(seconds: 0.1); m.keyUp(caps); m.run(seconds: 0.1)
            m.scheduleTyping("BASIC\rMODE 13:MOUSE ON\r", intervalMs: 40)
            m.run(seconds: 4)
            XCTAssertTrue(m.vidc.pointerShown, "\(rom): MOUSE ON shows the pointer")
            guard let e = m.currentFrame.displayArea else { return XCTFail("\(rom): no display area") }
            check(m, follower, [(e.x + 10, e.y + 10), (e.x + e.width - 20, e.y + e.height / 2), (e.x + e.width / 2 + 1, e.y + e.height / 2 + 1)], "\(rom) mode 13")
            // Once it's there, a program that moves the pointer isn't fought.
            let before = m.vidc.pointerHotspot
            m.scheduleTyping("MOUSE TO 100,100\r", intervalMs: 40)
            m.run(seconds: 3)
            let after = m.vidc.pointerHotspot
            XCTAssertTrue(abs(after.x - before.x) > 20 || abs(after.y - before.y) > 20, "\(rom): MOUSE TO moved it from \(before) (now \(after))")
        }
        if ran == 0 { throw XCTSkip("no RISC OS ROMs in ./roms") }
    }

    private func check(_ m: Machine, _ follower: PointerFollower, _ spots: [(Int, Int)], _ what: String) {
        for (x, y) in spots {
            follower.target = (x, y)
            m.run(seconds: 0.5)
            let p = m.vidc.pointerHotspot
            XCTAssertLessThanOrEqual(abs(p.x - x), 1, "\(what): sent to \(x), \(y); it's at \(p.x), \(p.y)")
            XCTAssertLessThanOrEqual(abs(p.y - y), 1, "\(what): sent to \(x), \(y); it's at \(p.x), \(p.y)")
        }
    }
}
