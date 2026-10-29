import ArchimedesCore
import Foundation

/// A Classic being played in a machine: its own setup, not the user's.
struct GameSession: Equatable {
    let gameID: String
    let title: String
    /// Where its CMOS is kept while it's played (it always starts from
    /// RISC OS's defaults).
    let cmosPath: String
    /// Its floppies' labels ("Disc 1", "Maps disc"), in order.
    let discLabels: [String]
}

/// The launcher a session's machine is stepped with. Only touched on the
/// emulation thread, inside `host.send`.
final class LauncherBox: @unchecked Sendable {
    var launcher: ClassicLauncher?
}

extension MachineController {
    /// Plays a Classic: a machine set up as the game wants (from a CMOS
    /// reset, without touching the machine in Settings), its first disc in
    /// (or its hard disc fitted), then started by its launcher, which also
    /// puts later discs in when the game asks. (The Mac app's.)
    func play(_ game: ClassicGame, floppies: [URL], hardDisc: URL?, cmosPath: String) async {
        let roms = AppSettings.shared.romLibrary
        guard let rom = game.machine.roms.lazy.compactMap({ family in roms.first { $0.version.hasPrefix(family) } }).first else {
            alert("\(game.title) needs \(game.machine.roms.joined(separator: " or "))",
                  "Add a \(game.machine.roms[0]) ROM with the main menu’s ROMs….")
            return
        }
        let images: [FloppyImage]
        do {
            images = try floppies.map { try FloppyImage.open(path: $0.path) }
        } catch {
            alert("Could not open \(game.title)’s discs", "\(error)")
            return
        }
        guard await confirmDiscChanges(before: "playing \(game.title)") else { return }
        stopSessionDiscs()
        playing = nil
        session = GameSession(gameID: game.id, title: game.title, cmosPath: cmosPath, discLabels: game.floppies.map(\.label))
        sessionDisc = 0
        try? FileManager.default.removeItem(atPath: cmosPath)
        let model = game.machine.model
        setHardware(model: model, cpu: model.defaultCPU, ramKB: game.machine.ramKB, monitor: .standard, romPath: rom.path,
                    hardDiscs: hardDisc.map { [$0.path] } ?? [], reload: true, keepingSession: true)
        guard let host, session?.gameID == game.id else { return }
        let box = launcherBox
        host.send { s in
            s.machine.ejectFloppy()
            if let first = images.first { s.machine.insertFloppy(first) }
            box.launcher = ClassicLauncher(game: game, floppies: images, machine: s.machine)
        }
        sessionDiscsActive = images.count > 1
        startLauncherTimer()
    }

    /// Puts another of the session's discs in (Machine ▸ Next Disc).
    func insertSessionDisc(_ index: Int) {
        guard let session, session.discLabels.indices.contains(index) else { return }
        let box = launcherBox
        host?.send { s in box.launcher?.insert(index, s.machine) }
    }

    /// "Insert Disc 2", for the menu.
    var nextSessionDiscTitle: String {
        guard let session, sessionDiscsActive, session.discLabels.count > 1 else { return "Next Disc" }
        return "Insert " + session.discLabels[(sessionDisc + 1) % session.discLabels.count]
    }

    func insertNextSessionDisc() {
        guard let session, session.discLabels.count > 1 else { return }
        insertSessionDisc((sessionDisc + 1) % session.discLabels.count)
    }

    /// The machine goes back to being the user's own.
    func endSession() {
        session = nil
        stopSessionDiscs()
    }

    /// Stops watching the game (another disc's gone in by hand).
    func stopSessionDiscs() {
        launcherTimer?.invalidate()
        launcherTimer = nil
        sessionDiscsActive = false
        let box = launcherBox
        host?.send { _ in box.launcher = nil }
    }

    private func startLauncherTimer() {
        launcherTimer?.invalidate()
        launcherTimer = GLibTimer(interval: 0.25) { [weak self] in
            guard let self else { return false }
            self.stepLauncher()
            return true
        }
    }

    private func stepLauncher() {
        let box = launcherBox
        host?.send { [weak self] s in
            guard let event = box.launcher?.step(s.machine) else { return }
            DispatchQueue.main.async { self?.launcherDid(event) }
        }
    }

    private func launcherDid(_ event: ClassicLauncher.Event) {
        if case .inserted(let index) = event {
            sessionDisc = index
        }
    }
}
