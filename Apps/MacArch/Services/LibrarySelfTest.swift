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

    /// MACARCH_SELFTEST_CLASSICS=<folder of the Classics' discs>: they're
    /// added as if downloaded, the Archimedes Classics shelf is captured
    /// (-classics.png), then MACARCH_SELFTEST_CLASSIC (a game's ID, Zarch
    /// if not given) is played and captured (-classic.png), with a report.
    /// MACARCH_SELFTEST_CLASSIC_NEXT_DISC=<seconds> has Next Disc chosen then.
    static func runClassics(_ path: String, folder: String, machine: MachineController) {
        let env = ProcessInfo.processInfo.environment
        var report = ""
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let classics = ClassicsLibrary.shared
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            let others = await classics.add(files)
            report += "Added \(files.count - others.count) of \(files.count) files; installed: "
                + classics.catalogue.games.filter { classics.state(of: $0) == .installed }.map(\.id).joined(separator: ", ") + "\n"
            report += "Partly: " + classics.catalogue.games.compactMap { game in
                if case .partial(let have, let of) = classics.state(of: game) { return "\(game.id) \(have)/\(of)" }
                return nil
            }.joined(separator: ", ") + "\n"
            AppSettings.store.set(ShelfTab.classics.rawValue, forKey: "MacArchLibraryTab")
            NotificationCenter.default.post(name: openRequest, object: nil)
            try? await Task.sleep(for: .seconds(3))
            capture(title: GameLibraryView.title, to: path.replacingOccurrences(of: ".png", with: "-classics.png"))
            guard let game = classics.catalogue.game(id: env["MACARCH_SELFTEST_CLASSIC"] ?? "zarch") else {
                report += "No such game\n"
                try? report.write(toFile: path + ".classics.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            MachineController.frontmost = machine
            Player.play(game) {}
            report += "Playing \(game.title): session \(machine.session?.gameID ?? "none"), \(machine.machineName), \(machine.romVersion), discs \(machine.session?.discLabels ?? [])\n"
            let seconds = Double(env["MACARCH_SELFTEST_LIBRARY_SECONDS"] ?? "") ?? 60
            if let next = Double(env["MACARCH_SELFTEST_CLASSIC_NEXT_DISC"] ?? "") {
                try? await Task.sleep(for: .seconds(next))
                report += "\(machine.nextSessionDiscTitle)\n"
                machine.insertNextSessionDisc()
                try? await Task.sleep(for: .seconds(max(0, seconds - next)))
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            report += "Disc in: \(machine.session.flatMap { $0.discLabels.indices.contains(machine.sessionDisc) ? $0.discLabels[machine.sessionDisc] : nil } ?? "no floppy"), \(machine.discName ?? "none")\n"
            report += "Window: \(machine.title)\n"
            if let frame = machine.host?.frame, let data = try? PNGEncoder.encode(frame, scaleX: frame.scaleX, scaleY: frame.scaleY) {
                try? data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-classic.png")))
            }
            report += "Settings' machine: \(AppSettings.shared.model.displayName), \(AppSettings.shared.romPath ?? "no ROM")\n"
            try? report.write(toFile: path + ".classics.txt", atomically: true, encoding: .utf8)
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
