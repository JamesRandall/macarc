import XCTest
@testable import ArchimedesCore

/// Frames say where the display area sits inside VIDC's border, so the
/// app can crop the border away (View ▸ Border).
final class DisplayAreaTests: XCTestCase {
    func testTheDesktopsDisplayAreaIsInsideTheBorder() throws {
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("ROM not present in ./roms/riscos3_11") }
        var c = MachineConfiguration(model: .a3000)
        c.romPaths = [rom]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 8)
        let f = m.currentFrame
        let d = try XCTUnwrap(f.displayArea)
        XCTAssertEqual(d.width * f.scaleX, 640, "the desktop is 640 across")
        XCTAssertTrue([480, 512].contains(d.height * f.scaleY), "\(d.height * f.scaleY) high")
        XCTAssertTrue(d.x > 0 && d.y > 0 && d.x + d.width < f.width && d.y + d.height < f.height,
                      "\(d) is inside the \(f.width)x\(f.height) frame, with a border")
        // Outside the display area is all border colour.
        let border = f.pixels[0]
        for y in 0..<f.height where y < d.y || y >= d.y + d.height {
            XCTAssertTrue(f.pixels[(y * f.width)..<((y + 1) * f.width)].allSatisfy { $0 == border }, "line \(y)")
        }
    }
}
