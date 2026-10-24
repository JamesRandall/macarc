import XCTest
@testable import ArchimedesCore

/// The Distributed Mandelbrot protocol as the app reads it
/// (Examples/distributed-mandelbrot/protocol.md), and the observer that
/// follows a render from the frames.
final class MandelbrotProtocolTests: XCTestCase {
    typealias M = MandelbrotMessage

    static let bodies: [M.Body] = [
        .hello(M.Hello()),
        .welcome(M.Welcome(maxIterations: 64)),
        .ready(station: 2),
        .assign(.standard(tile: 157, epoch: 3)),
        .result(M.TileResult(tileId: 157, epoch: 3, x: 544, y: 112, width: 32, height: 16, counts: MandelbrotReference.tile(id: 157))),
        .ack(M.Ack(tileId: 157, epoch: 3, status: 0)),
        .complete(tiles: 300),
        .discover(nonce: 0x1234_5678),
        .start(nonce: 0x1234_5678, coordinator: 1),
        .stop(nonce: 9),
        .status(nonce: 9, state: 2, workerVersion: 1, coordinator: 0),
    ]

    func testRoundTrips() {
        for body in Self.bodies {
            let message = M(header: M.Header(runId: 0xCAFE_F00D, messageId: 7, sender: 2), body: body)
            let bytes = message.encoded()
            XCTAssertEqual(Array(bytes.prefix(4)), [0x4D, 0x41, 1, body.type])
            XCTAssertEqual(MandelbrotProtocol.decode(bytes), .success(message), body.name)
        }
    }

    /// The lengths protocol.md gives, which the guests check.
    func testPayloadLengths() {
        let lengths: [UInt8: Int] = [1: 4, 2: 8, 3: 1, 4: 28, 5: 11 + 512, 6: 5, 8: 2, 11: 4, 13: 5, 16: 4, 17: 7]
        for body in Self.bodies {
            XCTAssertEqual(M(body: body).encoded().count - 14, lengths[body.type], body.name)
        }
    }

    /// ASSIGN's 4.28 corners: the default view, -2.5 + 1.2i at the top left.
    func testAssign() {
        let first = M.Assign.standard(tile: 0, epoch: 1)
        XCTAssertEqual(first.startReal, -671_088_640)
        XCTAssertEqual(first.startImag, 322_122_547)
        XCTAssertEqual(MandelbrotProtocol.real(first.stepReal), 0.005, accuracy: 1e-8)
        XCTAssertEqual(MandelbrotProtocol.real(first.stepImag), -0.01, accuracy: 1e-8)
        let last = M.Assign.standard(tile: 299, epoch: 1)
        XCTAssertEqual(last.x, 608)
        XCTAssertEqual(last.y, 224)
        XCTAssertEqual(last.startReal, -671_088_640 + 608 * 1_342_177)
        XCTAssertEqual(MandelbrotProtocol.origin(ofTile: 21).x, 32)
        XCTAssertEqual(MandelbrotProtocol.origin(ofTile: 21).y, 16)
    }

    func testColours() {
        XCTAssertEqual(MandelbrotProtocol.colour(64, max: 64), 0)
        XCTAssertEqual(MandelbrotProtocol.colour(1, max: 64), 1)
        XCTAssertEqual(MandelbrotProtocol.colour(14, max: 64), 14)
        XCTAssertEqual(MandelbrotProtocol.colour(15, max: 64), 1)
    }

    /// What a receiver ignores.
    func testRejects() {
        let good = M(body: .ready(station: 2)).encoded()
        XCTAssertEqual(MandelbrotProtocol.decode(good.prefix(13)), .failure(.tooShort(13)))
        var bad = good; bad[1] = 0x42
        XCTAssertEqual(MandelbrotProtocol.decode(bad), .failure(.badMagic))
        bad = good; bad[2] = 2
        XCTAssertEqual(MandelbrotProtocol.decode(bad), .failure(.badVersion(2)))
        XCTAssertEqual(MandelbrotProtocol.decode(good + [0]), .failure(.lengthMismatch(declared: 1, received: 2)))
        bad = good; bad[3] = 7
        XCTAssertEqual(MandelbrotProtocol.decode(bad), .failure(.unknownType(7)))
        bad = good; bad[3] = 1
        guard case .failure(.wrongPayloadLength) = MandelbrotProtocol.decode(bad) else { return XCTFail("HELLO of 1 byte") }
        // A RESULT whose counts aren't width × height.
        var result = M(body: .result(M.TileResult(tileId: 0, epoch: 1, x: 0, y: 0, width: 32, height: 16, counts: [1, 2, 3]))).encoded()
        guard case .failure(.wrongPayloadLength) = MandelbrotProtocol.decode(result) else { return XCTFail("short RESULT") }
        result[12] = 14
        guard case .failure(.wrongPayloadLength) = MandelbrotProtocol.decode(result) else { return XCTFail("RESULT, length fixed") }
    }

    // MARK: Frames

    /// A scout and its data, as the trace has them.
    final class Frames {
        var frames: [EconetFrame] = []
        var transaction = 0
        var time: UInt64 = 0

        func send(_ body: M.Body, from: UInt8, to: UInt8, port: UInt8, runId: UInt32 = 0xAB) {
            transaction += 1
            time += 24_000
            frames.append(EconetFrame(id: frames.count, start: time, end: time + 100, transmitter: from,
                                      bytes: [to, 0, from, 0, 0x80, port], status: .valid, kind: .scout, transaction: transaction))
            frames.append(EconetFrame(id: frames.count, start: time + 200, end: time + 300, transmitter: to, bytes: [from, 0, to, 0],
                                      status: .valid, kind: .acknowledgement, transaction: transaction))
            let data = M(header: M.Header(runId: runId, sender: from), body: body).encoded()
            frames.append(EconetFrame(id: frames.count, start: time + 400, end: time + 900, transmitter: from,
                                      bytes: [to, 0, from, 0] + data, status: .valid, kind: .data, transaction: transaction))
        }

        func toCoordinator(_ body: M.Body, from worker: UInt8, runId: UInt32 = 0xAB) { send(body, from: worker, to: 1, port: 0xC0, runId: runId) }
        func toWorker(_ body: M.Body, _ worker: UInt8) { send(body, from: 1, to: worker, port: 0xC1) }
    }

    func testTrafficPairsDataWithItsScout() {
        let f = Frames()
        f.toWorker(.discover(nonce: 5), 2)
        f.send(.ready(station: 2), from: 2, to: 1, port: 0x99) // not the demo's port
        var traffic = MandelbrotTraffic()
        let readings = f.frames.compactMap { traffic.read($0) }
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.port, 0xC1)
        XCTAssertEqual(readings.first?.summary, "DISCOVER → station 2")
    }

    /// A render as the observer follows it: a worker registers, takes a
    /// tile, sends it, and it's accepted and drawn; a late result is stale.
    func testObserverFollowsARender() {
        let f = Frames()
        f.toWorker(.discover(nonce: 0xAB), 2)
        f.toCoordinator(.status(nonce: 0xAB, state: 2, workerVersion: 1, coordinator: 0), from: 2, runId: 0)
        f.toCoordinator(.hello(M.Hello()), from: 2, runId: 0)
        f.toWorker(.welcome(M.Welcome(maxIterations: 64)), 2)
        f.toCoordinator(.ready(station: 2), from: 2)
        f.toWorker(.assign(.standard(tile: 21, epoch: 1)), 2)
        var observer = MandelbrotObserver()
        observer.observe(f.frames)
        XCTAssertEqual(observer.coordinator, 1)
        XCTAssertEqual(observer.workers[2]?.state, .computing)
        XCTAssertEqual(observer.inFlight.map(\.tile), [21])

        let counts = MandelbrotReference.tile(id: 21)
        f.toCoordinator(.result(M.TileResult(tileId: 21, epoch: 1, x: 32, y: 16, width: 32, height: 16, counts: counts)), from: 2)
        f.toWorker(.ack(M.Ack(tileId: 21, epoch: 1, status: 0)), 2)
        f.toWorker(.ack(M.Ack(tileId: 21, epoch: 0, status: 2)), 2)
        observer = MandelbrotObserver()
        observer.observe(f.frames)
        XCTAssertEqual(observer.tilesCompleted, 1)
        XCTAssertEqual(observer.workers[2]?.tiles, 1)
        XCTAssertEqual(observer.workers[2]?.stale, 1)
        XCTAssertEqual(observer.workers[2]?.state, .idle)
        XCTAssertEqual(observer.count(x: 32, y: 16), counts[0])
        XCTAssertEqual(observer.count(x: 63, y: 31), counts[511])
        XCTAssertNil(observer.count(x: 0, y: 0))
        XCTAssertFalse(observer.completeSeen)

        f.toWorker(.complete(tiles: 300), 2)
        observer.observe(f.frames.suffix(3))
        XCTAssertTrue(observer.completeSeen)
        XCTAssertEqual(observer.malformed, 0)
    }

    /// A tile out longer than the coordinator waits: the worker's unresponsive.
    func testObserverTimesOut() {
        let f = Frames()
        f.toCoordinator(.hello(M.Hello()), from: 3, runId: 0)
        f.toWorker(.welcome(M.Welcome(maxIterations: 64)), 3)
        f.toWorker(.assign(.standard(tile: 0, epoch: 1)), 3)
        var observer = MandelbrotObserver()
        observer.observe(f.frames)
        observer.advance(to: f.time + MandelbrotObserver.timeout + 24_000_000)
        XCTAssertEqual(observer.workers[3]?.state, .unresponsive)
    }
}

/// The trace's reading of the four-way handshake when a data frame is lost.
final class EconetTraceHandshakeTests: XCTestCase {
    func frame(_ trace: EconetTrace, from station: UInt8, _ bytes: [UInt8], at time: inout UInt64) {
        for b in bytes { trace.observe(EconetLineEvent(time: time, station: station, symbol: .byte(b), collided: false)); time += 960 }
        for _ in 0..<2 { trace.observe(EconetLineEvent(time: time, station: station, symbol: .check, collided: false)); time += 960 }
        trace.observe(EconetLineEvent(time: time, station: station, symbol: .flag, collided: false))
        time += 2_000
    }

    /// The scout's acknowledged, the data never comes, and 5 cs later the
    /// sender tries again: the new scout is a scout, not the lost data.
    func testRetryAfterLostDataIsAScout() {
        let trace = EconetTrace()
        var t: UInt64 = 0
        frame(trace, from: 1, [3, 0, 1, 0, 0x80, 0xC1], at: &t)
        frame(trace, from: 3, [1, 0, 3, 0], at: &t)
        t += 5 * 240_000
        frame(trace, from: 1, [3, 0, 1, 0, 0x80, 0xC1], at: &t)
        frame(trace, from: 3, [1, 0, 3, 0], at: &t)
        frame(trace, from: 1, [3, 0, 1, 0] + MandelbrotMessage(body: .complete(tiles: 300)).encoded(), at: &t)
        XCTAssertEqual(trace.frames.map(\.kind), [.scout, .acknowledgement, .scout, .acknowledgement, .data])
        var traffic = MandelbrotTraffic()
        let readings = trace.frames.compactMap { traffic.read($0) }
        XCTAssertEqual(readings.map(\.summary), ["COMPLETE 300 tiles → station 3"])
    }
}
