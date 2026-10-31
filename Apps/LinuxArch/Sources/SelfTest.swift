import ArchimedesCore
import CGtk
import Foundation

/// Opt-in automation, as MacArch's MACARCH_SELFTEST: `LINUXARCH_SELFTEST=out.png`
/// runs the first window's machine, then writes the frame (out.png), the
/// window as shown (out-window.png) and a report (out.txt), and quits.
/// Settings, profiles and ROMs are kept apart from the user's.
///
/// - LINUXARCH_SELFTEST_ROM: a ROM to add and switch on with.
/// - LINUXARCH_SELFTEST_MODEL: the model (A3000, A440/1, …).
/// - LINUXARCH_SELFTEST_SECONDS: how long to run first (default 20).
/// - LINUXARCH_SELFTEST_DISC: a floppy image to put in drive 0.
/// - LINUXARCH_SELFTEST_TYPE: text to type once it's running.
/// - LINUXARCH_SELFTEST_STYLE / _BORDER: the display style and border.
/// - LINUXARCH_SELFTEST_OPEN: actions whose dialogs or windows to open and
///   capture in turn (out-NAME.png), e.g. "app.preferences,win.configure";
///   a target follows a colon ("win.disc-contents:0").
/// - LINUXARCH_SELFTEST_ADD_GAMES: files to add to My Games (comma
///   separated), saving the details as they're guessed.
/// - LINUXARCH_SELFTEST_PLAY: "first" plays the first of My Games.
/// - LINUXARCH_SELFTEST_MYMACHINES: saves the machine to My Machines,
///   starts it from there, creates another with Create Machine (an A5000
///   with a new hard disc, if a ROM suits one) and starts that, capturing
///   the gallery (out-mymachines.png, out-mymachines2.png), the Create
///   Machine dialog (out-create.png) and the machines' windows
///   (out-mymachine.png, out-created.png).
@MainActor
final class SelfTest {
    static let current: SelfTest? = {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["LINUXARCH_SELFTEST"], !output.isEmpty else { return nil }
        return SelfTest(output: URL(fileURLWithPath: output), environment: environment)
    }()

    private let output: URL
    private let environment: [String: String]
    private var log: [String] = []

    private init(output: URL, environment: [String: String]) {
        self.output = output
        self.environment = environment
    }

    func run(_ window: MachineWindow) {
        Task { @MainActor in
            await self.start(window)
        }
    }

    private func start(_ window: MachineWindow) async {
        let machine = window.machine
        if let style = environment["LINUXARCH_SELFTEST_STYLE"].flatMap(DisplayStyle.init(rawValue:)) { machine.displayStyle = style }
        if let border = environment["LINUXARCH_SELFTEST_BORDER"].flatMap(DisplayBorder.init(rawValue:)) { machine.displayBorder = border }
        if let rom = environment["LINUXARCH_SELFTEST_ROM"] {
            let added = await ROMLibrary.shared.add([URL(fileURLWithPath: rom)])
            note("rom added: \(added.map(\.found.rom.versionString))")
            if let path = added.first?.path {
                let model = environment["LINUXARCH_SELFTEST_MODEL"].flatMap(MachineModel.init(rawValue:))
                machine.setHardware(model: model, romPath: path)
            }
        }
        note("rom library: \(AppSettings.shared.romLibrary.map(\.version))")
        guard machine.host != nil else {
            note("not running: \(machine.startError ?? "no ROM")")
            // (Long enough for the window to be drawn.)
            after(3) { [weak self] in self?.finish(window) }
            return
        }
        if let disc = environment["LINUXARCH_SELFTEST_DISC"] {
            await machine.insertDisc(URL(fileURLWithPath: disc))
            note("disc: \(machine.discName ?? "none")")
        }
        if let games = environment["LINUXARCH_SELFTEST_ADD_GAMES"] {
            GameLibraryWindow.show()
            GameLibrary.shared.addFiles(games.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            try? await Task.sleep(for: .seconds(2))
            GameDetailsDialog.saveFront()
            try? await Task.sleep(for: .seconds(1))
            note("my games: \(GameLibrary.shared.personalGames.map { "\($0.title) (\($0.start), \($0.machineSummary))" })")
        }
        if environment["LINUXARCH_SELFTEST_PLAY"] == "first", let game = GameLibrary.shared.personalGames.first {
            Player.play(game)
            note("playing \(game.title)")
        }
        let seconds = Double(environment["LINUXARCH_SELFTEST_SECONDS"] ?? "") ?? 20
        if let text = environment["LINUXARCH_SELFTEST_TYPE"] {
            after(seconds * 0.6) { machine.type(text.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        after(seconds) { [weak self] in self?.finish(window) }
    }

    private func note(_ line: String) {
        log.append(line)
        print("selftest: \(line)")
    }

    private func finish(_ window: MachineWindow) {
        let machine = window.machine
        if let host = machine.host {
            let frame = host.frame
            note("machine: \(machine.machineName), \(machine.romVersion), \(AppSettings.ramLabel(machine.ramKB))")
            note("guest seconds: \(String(format: "%.1f", host.guestSeconds))")
            note("frame: \(frame.frameNumber), \(frame.width)x\(frame.height), scale \(frame.scaleX)x\(frame.scaleY), "
                 + "display area \(frame.displayArea.map { "\($0.x),\($0.y) \($0.width)x\($0.height)" } ?? "none"), "
                 + "colours \(Set(frame.pixels).count)")
            note("lights: \(machine.lights)")
            note("title: \(machine.title.title)")
            let text = host.sendAndWait { $0.machine.screenText }
            note("screen text:\n" + text.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(12).joined(separator: "\n"))
            if frame.width > 1 {
                try? Data(PNGEncoder.encode(frame, scaleX: frame.scaleX, scaleY: frame.scaleY)).write(to: output)
            }
            // The picture as the window draws it (its style and border).
            if let shown = window.emulator.renderImage(width: 832, height: 624) {
                let bytes = shown.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
                if let texture = gdk_memory_texture_new(832, 624, GDK_MEMORY_B8G8R8A8, bytes, 832 * 4) {
                    let path = output.deletingPathExtension().path + "-rendered.png"
                    note("rendered: \(gdk_texture_save_to_png(texture, path) != 0)")
                    g_object_unref(texture.raw)
                }
                g_bytes_unref(bytes)
            }
        }
        let windowPNG = output.deletingPathExtension().path + "-window.png"
        note("window capture: \(la_save_widget_png(window.window, windowPNG) != 0)")
        let opens = (environment["LINUXARCH_SELFTEST_OPEN"] ?? "").split(separator: ",").map(String.init)
        guard environment["LINUXARCH_SELFTEST_MYMACHINES"] != nil, machine.host != nil else {
            capture(opens[...], in: window)
            return
        }
        Task { @MainActor in
            await self.myMachines(machine)
            self.capture(opens[...], in: window)
        }
    }

    /// Saves, creates and starts My Machines entries (as the Mac app's
    /// MyMachinesSelfTest).
    private func myMachines(_ machine: MachineController) async {
        func capture(_ widget: Widget?, _ suffix: String) {
            guard let widget else { return note("\(suffix): no window") }
            note("\(suffix): \(la_save_widget_png(widget, output.deletingPathExtension().path + "-\(suffix).png") != 0)")
        }
        func windowOf(_ controller: MachineController) -> Widget? {
            MachineWindow.all.first { $0.machine === controller }?.window
        }
        let machines = MyMachines.shared
        do {
            let id = try await machines.save(machine, name: "Self-test \(machine.model.rawValue)")
            guard let entry = machines.entry(id) else { throw MachineError.badConfiguration("saved entry missing") }
            let files = ["info.json", "machine.json", "machine.cmos", "screen.png"].filter {
                FileManager.default.fileExists(atPath: entry.folder.appendingPathComponent($0).path)
            }
            note("saved: \(entry.name) files=\(files) problem=\(entry.problem ?? "none") savedID=\(machine.savedMachineID == id)")
            let gallery = MyMachinesWindow.show()
            try await Task.sleep(for: .seconds(2))
            capture(gallery.window, "mymachines")

            let started = try await machines.prepare(id)
            MachineWindow(app: LinuxArchApp.shared.app, machine: started).present()
            try await Task.sleep(for: .seconds(4))
            note("started: model=\(started.model.rawValue) cpu=\(started.cpu.rawValue) ram=\(started.ramKB) rom=\(started.romVersion) running=\(started.host != nil) fromMyMachines=\(started.startedFromMyMachines) error=\(started.startError ?? "none")")
            capture(windowOf(started), "mymachine")

            // Created by hand: an A5000 with a new hard disc, never started.
            let settings = AppSettings.shared
            let model: MachineModel = settings.preferredROM(for: .a5000) != nil ? .a5000 : .a440
            var discs: [String?] = Array(repeating: nil, count: model.hardDiscSlots)
            let disc = (AppSettings.supportDirectory as NSString).appendingPathComponent("Created \(model.rawValue.replacingOccurrences(of: "/", with: "-")) drive 4.hdf")
            try? FileManager.default.removeItem(atPath: disc)
            let geometry = (model.hasIDE ? HardDiscGeometry.idePresets : HardDiscGeometry.presets)[0].geometry
            try ADFSFormatter.createFormattedImage(path: disc, geometry: geometry, name: "Created", system: true)
            discs[0] = disc
            gallery.showCreate()
            try await Task.sleep(for: .seconds(1.5))
            capture(gallery.window, "create")
            let name = "Created \(model.rawValue)"
            gallery.createForSelfTest(name: name, model: model, cpu: model.cpuChoices.last ?? model.defaultCPU,
                                      ramKB: model.ramChoices.last ?? model.defaultRAMKB, monitor: model.monitorChoices.last ?? .standard,
                                      hardDiscs: discs)
            guard let made = machines.entries.first(where: { $0.name == name }) else { throw MachineError.badConfiguration("created entry missing") }
            note("created: rom=\(MachineTiles.rom(made) ?? "none") keys=\(made.configuration?.powerOnKeys ?? []) cmos=\(made.configuration?.cmosPath ?? "none") summary=\(MachineTiles.summary(made))")
            let second = try await machines.prepare(made.id)
            MachineWindow(app: LinuxArchApp.shared.app, machine: second).present()
            try await Task.sleep(for: .seconds(3))
            let after = machines.entry(made.id)?.configuration
            note("created started: model=\(second.model.rawValue) cpu=\(second.cpu.rawValue) ram=\(second.ramKB) monitor=\(second.monitor.rawValue) rom=\(second.romVersion) running=\(second.host != nil) error=\(second.startError ?? "none")")
            note("after first start: keys=\(after?.powerOnKeys ?? [99]) cmos=\(after?.cmosPath ?? "none") hardDiscs=\(second.hardDiscs.map { $0.map { ($0 as NSString).lastPathComponent } ?? "-" })")
            // Delete held at its first start: RISC OS sets its CMOS up.
            try await Task.sleep(for: .seconds(8))
            let (_, cmos, _) = try await second.currentSetup()
            note("created CMOS set up: \(!Machine.cmosNeverConfigured(cmos))")
            capture(windowOf(second), "created")
            // Update “name” in My Machines: its screen and CMOS saved back.
            try await machines.save(second, name: made.name, over: made.id)
            let updated = machines.entry(made.id)
            note("updated: screen=\(updated.map { FileManager.default.fileExists(atPath: $0.screenURL.path) } ?? false) entries=\(machines.entries.count) running=\(machines.entries.filter { machines.running($0.id) != nil }.map(\.name))")
            gallery.select(named: made.name)
            gallery.present()
            try await Task.sleep(for: .seconds(1.5))
            capture(gallery.window, "mymachines2")
        } catch {
            note("my machines error: \(error)")
        }
    }

    /// The app's windows.
    private static var windows: [Widget] {
        var found: [Widget] = []
        var node = gtk_application_get_windows(LinuxArchApp.shared.app.cast())
        while let current = node {
            if let data = current.pointee.data { found.append(data.widget) }
            node = current.pointee.next
        }
        return found
    }

    /// Opens each action's dialog or window, captures it (a dialog with the
    /// window it's over), and closes it. An action's target follows a colon:
    /// "win.rewind:5".
    private func capture(_ actions: ArraySlice<String>, in window: MachineWindow) {
        guard let action = actions.first else {
            quit(window)
            return
        }
        let (name, target) = action.firstIndex(of: ":").map { (String(action[..<$0]), String(action[action.index(after: $0)...])) } ?? (action, nil)
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let group: OpaquePointer = parts.first == "app" ? LinuxArchApp.shared.app : window.window.opaque
        let before = Self.windows
        g_action_group_activate_action(group, parts.last ?? name, target.map { g_variant_new_string($0) })
        after(Double(environment["LINUXARCH_SELFTEST_WAIT"] ?? "") ?? 1.5) { [weak self] in
            guard let self else { return }
            let path = self.output.deletingPathExtension().path + "-\(parts.last ?? name)\(target.map { "-" + $0 } ?? "").png"
            // A new window, or one that was open already and came forward.
            let active = gtk_application_get_active_window(LinuxArchApp.shared.app.cast()).map { $0.widget }
            let new = Self.windows.first(where: { !before.contains($0) })
            if let opened = new ?? (active != window.window ? active : nil) {
                self.note("\(action): window \(la_save_widget_png(opened, path) != 0)")
                // (Only those the action opened: one it brought forward, a
                // network's studio say, stays for the next.)
                if new != nil { gtk_window_close(opened.cast()) }
            } else {
                self.note("\(action): \(la_save_widget_png(window.window, path) != 0)")
            }
            if let dialog = adw_application_window_get_visible_dialog(window.window.cast()) {
                adw_dialog_force_close(dialog)
            }
            after(0.5) { [weak self] in self?.capture(actions.dropFirst(), in: window) }
        }
    }

    private func quit(_ window: MachineWindow) {
        try? log.joined(separator: "\n").appending("\n").write(to: output.deletingPathExtension().appendingPathExtension("txt"),
                                                               atomically: true, encoding: .utf8)
        window.forceClose()
        g_application_quit(LinuxArchApp.shared.app.cast())
    }
}
