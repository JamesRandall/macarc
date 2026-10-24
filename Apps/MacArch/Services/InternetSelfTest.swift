import AppKit
import ArchimedesCore
import SwiftUI

/// Two apps in one Internet Econet room, on the service in
/// MACARCH_SELFTEST_ECONET_SERVICE (a local one from acornplayground's
/// `npm run dev` will do). The other can be MacArch or MacBeeb (whose own
/// self-test plays the same parts):
///
/// - MACARCH_SELFTEST_INTERNET=host: the Distributed Mandelbrot's file
///   server and Guide, shared into a new room; the join code goes to
///   MACARCH_SELFTEST_INTERNET_CODE (else path.code), then it waits for the
///   guest to finish and captures its canvas and Internet sheet.
/// - MACARCH_SELFTEST_INTERNET=guest: waits for the code, joins with a new
///   network of one A3000, and on it *I AM GUEST and *CAT on the host's
///   file server.
///
/// Each writes what it saw to path.internet.txt. Credentials stay in memory.
@MainActor
enum InternetSelfTest {
    static func run(_ path: String, host: Bool) {
        let env = ProcessInfo.processInfo.environment
        let service = env["MACARCH_SELFTEST_ECONET_SERVICE"].flatMap { try? InternetEconetService.validate($0).get() } ?? InternetEconetService.current
        let codeFile = env["MACARCH_SELFTEST_INTERNET_CODE"] ?? path.replacingOccurrences(of: ".png", with: ".code")
        var report = "Service: \(service.absoluteString)\n"
        func finish() {
            try? report.write(toFile: path + ".internet.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        func screen(_ session: NetworkSession, _ id: UUID) -> String {
            session.controllers[id]?.host?.sendAndWait { $0.machine.screenText.joined(separator: "\n") } ?? "(off)"
        }
        func capture<V: View>(_ view: V, width: Double, height: Double, to file: String) async {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view.frame(width: width, height: height))
            window.orderBack(nil)
            try? await Task.sleep(for: .seconds(2))
            if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
            window.close()
        }

        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macarch-internet-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(host ? "Host" : "Guest").\(NetworkPackage.fileExtension)")
            if host {
                // The Distributed Mandelbrot's server and Guide, without its workers.
                guard var project = try? NetworkPackage.create(.distributedMandelbrot, at: url) else { return finish() }
                project.nodes.removeAll { $0.name.hasPrefix("Worker") }
                try? NetworkPackage.save(project, to: url)
                guard let session = try? NetworkSession.session(for: url),
                      let server = session.project.nodes.first(where: { $0.kind == .fileServer }) else { return finish() }
                for _ in 0..<90 where !(session.controllers[server.id]?.consoleLine ?? "").contains("Ready") {
                    try? await Task.sleep(for: .seconds(1))
                }
                report += "Server: \(session.controllers[server.id]?.consoleLine ?? "?")\n"
                do {
                    try await session.share(on: service, name: "Self-test Classroom", shared: Set(session.project.stations.map(\.id)),
                                            screenSharing: true, showsScreens: true)
                } catch {
                    report += "Share failed: \(error)\n"
                    return finish()
                }
                guard let code = session.currentInvite?.code else { return finish() }
                try? code.write(toFile: codeFile, atomically: true, encoding: .utf8)
                report += "Code: \(code)\n"
                var sawGuest = false
                var sawScreens: Set<Int> = []
                for _ in 0..<240 {
                    try? await Task.sleep(for: .seconds(1))
                    if !session.remoteStations.isEmpty { sawGuest = true }
                    sawScreens.formUnion(session.remoteScreens.keys)
                    if sawGuest && FileManager.default.fileExists(atPath: codeFile + ".done") { break }
                }
                report += "Saw the guest's station: \(sawGuest)\n"
                report += "Guest's screens seen: \(sawScreens.sorted())\n"
                report += "Room: \(String(describing: session.room?.state)), participants \(session.room?.participants.map { "\($0.name) (\($0.app))" } ?? [])\n"
                report += "Stations: \(session.room?.stations.map { "\($0.station) \($0.label) \($0.kind) \($0.online ? "online" : "offline")" } ?? [])\n"
                report += "Gateway: \(String(describing: session.internet?.gateway.counters))\n"
                await capture(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800,
                              to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
                await capture(InternetShareView(session: session), width: 520, height: 640,
                              to: path.replacingOccurrences(of: ".png", with: "-share.png"))
                await session.leaveRoom()
                finish()
            } else {
                var code: String?
                for _ in 0..<240 {
                    code = try? String(contentsOfFile: codeFile, encoding: .utf8)
                    if code != nil { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                guard let code else {
                    report += "No code from the host\n"
                    return finish()
                }
                report += "Code: \(code)\n"
                let api = RoomAPI(service: service)
                do {
                    let preview = try await api.resolve(code: code.lowercased().replacingOccurrences(of: "-", with: " "))
                    report += "Preview: \(preview.room.name), \(preview.participants) people, stations \(preview.stations.map { "\($0.station) \($0.label) \($0.kind)" })\n"
                    let joined = try await api.join(roomId: preview.roomId, code: code, displayName: "Guest Mac")
                    var project = NetworkProject(name: preview.room.name)
                    project.nodes = [
                        NetworkNode(kind: .station, name: "Visitor", stationNumber: 7, setup: StationSetup(model: .a3000), position: CanvasPoint()),
                        .clock(at: CanvasPoint(x: 0, y: NetworkProject.rowSpacing)),
                    ]
                    try NetworkPackage.save(project, to: url)
                    let session = try NetworkSession.session(for: url)
                    try session.enterRoom(service: service, roomId: preview.roomId, roomName: preview.room.name, joined: joined,
                                          shared: Set(session.project.stations.map(\.id)), showsScreens: preview.room.allowsScreens)
                    for _ in 0..<30 where !(session.internet?.gateway.remoteStations.contains(254) ?? false) {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    report += "Sees the server: \(session.internet?.gateway.remoteStations.sorted() ?? [])\n"
                    guard let visitor = session.project.stations.first, let controller = session.controllers[visitor.id] else {
                        report += "No machine\n"
                        return finish()
                    }
                    // RISC OS at its desktop: F12 for the command line.
                    try? await Task.sleep(for: .seconds(25))
                    controller.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); controller.keyUp(0x0C)
                    try? await Task.sleep(for: .seconds(1))
                    controller.type("I AM GUEST\n")
                    try? await Task.sleep(for: .seconds(8))
                    controller.type("CAT\n")
                    for _ in 0..<30 where !screen(session, visitor.id).contains("Option") {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    report += "Gateway: \(String(describing: session.internet?.gateway.counters))\n"
                    for _ in 0..<10 where session.remoteScreens.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                    report += "Host's screens seen: \(session.remoteScreens.keys.sorted())\n"
                    report += "Room participants: \(session.room?.participants.map { "\($0.name) (\($0.app))" } ?? [])\n"
                    report += "\n== Visitor\n\(screen(session, visitor.id))\n"
                    await capture(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800,
                                  to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
                    await session.leaveRoom()
                } catch {
                    report += "Failed: \(error)\n"
                }
                try? "done".write(toFile: codeFile + ".done", atomically: true, encoding: .utf8)
                finish()
            }
        }
    }
}
