@testable import ArchimedesCore

// The Distributed Mandelbrot demo's picture, worked out as its protocol
// (Examples/distributed-mandelbrot/protocol.md) says a worker does, for
// tests to compare the guests' results against byte for byte. Test-only:
// the app never works out a pixel itself.

enum MandelbrotReference {
    typealias P = MandelbrotProtocol

    static let two: UInt32 = 2 << 28
    static let four: UInt32 = 4 << 28

    /// The escape count of `(cr, ci)` with limit `max`: 1 … max. In 4.28,
    /// the products of the magnitudes truncated and the sign put back,
    /// wrapping as 32-bit registers do.
    static func escapeCount(cr: Int32, ci: Int32, max: Int) -> Int {
        var x: Int32 = 0, y: Int32 = 0
        for n in 0 ..< max {
            let ax = x.magnitude, ay = y.magnitude
            if ax >= two || ay >= two { return n }
            let x2 = UInt32((UInt64(ax) * UInt64(ax)) >> 28)
            let y2 = UInt32((UInt64(ay) * UInt64(ay)) >> 28)
            if x2 + y2 > four { return n }
            var xy = Int32((UInt64(ax) * UInt64(ay)) >> 28)
            if (x < 0) != (y < 0) { xy = -xy }
            y = 2 &* xy &+ ci
            x = Int32(bitPattern: x2 &- y2) &+ cr
        }
        return max
    }

    /// Pixel (x, y) of the picture, in the default view.
    static func count(x: Int, y: Int, maxIterations: Int = P.defaultMaxIterations) -> UInt8 {
        UInt8(escapeCount(cr: P.viewLeft &+ Int32(x) &* P.stepReal, ci: P.viewTop &+ Int32(y) &* P.stepImag, max: maxIterations))
    }

    /// A tile's counts, row by row from the top, as its RESULT has them.
    static func tile(id: Int, maxIterations: Int = P.defaultMaxIterations) -> [UInt8] {
        let (x0, y0) = P.origin(ofTile: id)
        return (0 ..< P.tileHeight).flatMap { dy in
            (0 ..< P.tileWidth).map { dx in count(x: x0 + dx, y: y0 + dy, maxIterations: maxIterations) }
        }
    }

    /// The whole picture, 640 × 240 counts row by row.
    static func image(maxIterations: Int = P.defaultMaxIterations) -> [UInt8] {
        (0 ..< P.imageHeight).flatMap { y in (0 ..< P.imageWidth).map { x in count(x: x, y: y, maxIterations: maxIterations) } }
    }

    /// The picture's colours (0 inside the set, 1-14 the bands).
    static func colours(maxIterations: Int = P.defaultMaxIterations) -> [UInt8] {
        image(maxIterations: maxIterations).map { UInt8(P.colour(Int($0), max: maxIterations)) }
    }
}
