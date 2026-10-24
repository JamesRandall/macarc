import AppKit
import ArchimedesCore
import SwiftUI

/// MACARCH_SELFTEST_LIBRARY=<disc image>: the Game Library with one game
/// of the user's own (that disc, started with MACARCH_SELFTEST_LIBRARY_START,
/// a command typed at the command line; else just put in), in a library of
/// its own (MACARCH_SELFTEST_LIBRARY_START=boot: from the disc's !Boot); the shelf is captured (-library.png), then the game played in
/// the self-test's machine and captured (-playing.png), with a report.
@MainActor
enum LibrarySelfTest {
    static let openRequest = Notification.Name("MacArchOpenGameLibrary")

    static func run(_ path: String, disc: String, machine: MachineController) {
        let env = ProcessInfo.processInfo.environment
        var report = ""
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let library = GameLibrary.shared
            do {
                let file = try MyGames.readDisc(at: URL(fileURLWithPath: disc))
                var game = PersonalGame(title: file.suggestedTitle, publisher: "Self-test", year: file.suggestedYear)
                game.start = file.suggestedStart
                if let command = env["MACARCH_SELFTEST_LIBRARY_START"] { game.start = command == "boot" ? .boot : .type(command) }
                report += "Starts: \(game.start), applications \(file.applications)\n"
                let added = try await library.myGames.add(game, disc: file, cover: nil)
                await library.refresh()
                report += "Added: \(added.title), disc \(added.discFile ?? "none"), \(library.personalGames.count) game(s)\n"
                NotificationCenter.default.post(name: openRequest, object: nil)
                try? await Task.sleep(for: .seconds(3))
                capture(title: GameLibraryView.title, to: path.replacingOccurrences(of: ".png", with: "-library.png"))
                MachineController.frontmost = machine
                Player.play(added) {}
                report += "Playing: \(machine.playing == added.id)\n"
                try? await Task.sleep(for: .seconds(Double(env["MACARCH_SELFTEST_LIBRARY_SECONDS"] ?? "") ?? 45))
                if let frame = machine.host?.frame,
                   let data = try? PNGEncoder.encode(frame, scaleX: frame.scaleX, scaleY: frame.scaleY) {
                    try? data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-playing.png")))
                }
                report += "Screen:\n" + (machine.host?.sendAndWait { $0.machine.screenText.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n") } ?? "") + "\n"
            } catch {
                report += "Failed: \(error)\n"
            }
            try? report.write(toFile: path + ".library.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func capture(title: String, to file: String) {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}
