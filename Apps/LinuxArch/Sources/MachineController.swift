import ArchimedesCore
import CGtk
import Foundation
import MacArchAgent
import Observation

/// What a network station's controller tells its network (instead of
/// remembering its hardware in the app's settings).
@MainActor
protocol StationOwner: AnyObject {
    /// Its hardware changed (model, processor, memory, monitor, ROM).
    func stationSetupChanged(_ controller: MachineController)
    /// A disc is going in: the network's copy of it to use instead.
    func station(_ controller: MachineController, willInsert source: URL, drive: Int) -> URL?
    /// Hard discs are being fitted: the network's copies to use instead.
    func station(_ controller: MachineController, willFitHardDiscs paths: [String?]) -> [String?]
    func station(_ controller: MachineController, didEject drive: Int)
    func stationNumber(_ controller: MachineController) -> Int?
    func stationCMOSPath(_ controller: MachineController) -> String?
    /// Configuration the station keeps whatever RISC OS is told.
    func stationCMOSSettings(_ controller: MachineController) -> [CMOSSetting]
    func stationTitle(_ controller: MachineController) -> String
}

/// One emulated Archimedes and its window's actions. (The Mac app's
/// MachineController, nearly line for line: libadwaita's dialogs are
/// asynchronous, so what asks the user is too.)
@MainActor
@Observable
final class MachineController {
    /// Runs the machine; nil until a ROM is chosen.
    private(set) var host: EmulatorHost?
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private lazy var tee = AudioTee(output: audio)

    private(set) var paused = false
    private(set) var speedLimited = true
    var muted = false { didSet { audio.muted = muted } }

    /// The floppy drives' noises, in every window but network stations'.
    static func setDiscDriveSounds(_ on: Bool) {
        AppSettings.shared.discDriveSounds = on
        for c in live where !c.isStation { c.host?.setDrivesHeard(on) }
    }
    /// The ROM's version, e.g. "RISC OS 3.11 (29 Sep 1992)".
    private(set) var romVersion = ""
    private(set) var romPath: String?
    private(set) var model = AppSettings.shared.model
    private(set) var cpu = AppSettings.shared.cpu(for: AppSettings.shared.model)
    private(set) var ramKB = AppSettings.shared.ramKB(for: AppSettings.shared.model)
    private(set) var monitor = AppSettings.shared.monitor(for: AppSettings.shared.model)
    /// Hard disc image paths by drive (400 series and the A5000 family).
    private(set) var hardDiscs = AppSettings.shared.hardDiscs(for: AppSettings.shared.model)
    private(set) var discName: String?
    /// Drive 0 holds a new disc that has never been saved to a file.
    private(set) var discIsUntitled = false
    /// Whether drive 0's disc has unsaved changes, and whether they can be saved.
    private(set) var disc = EmulatorHost.DiscState()
    private(set) var lights = Machine.Lights()
    /// Why the machine could not start, for the setup page.
    private(set) var startError: String?
    /// A passing message for the window ("State saved"), shown as a toast.
    private(set) var toast: String?

    /// How the window draws the picture. Shared by all windows.
    var displayStyle = DisplayStyle.saved {
        didSet { Preferences.standard.set(displayStyle.rawValue, forKey: DisplayStyle.defaultsKey) }
    }
    var displayBorder = DisplayBorder.saved {
        didSet { Preferences.standard.set(displayBorder.rawValue, forKey: DisplayBorder.defaultsKey) }
    }
    /// The window, for dialogs, zoom and the mouse.
    @ObservationIgnored weak var window: MachineWindow?
    @ObservationIgnored private var lightsTimer: GLibTimer?

    /// Every machine: open windows', and networks' stations (with or
    /// without windows), for the quit check and hard discs in use.
    static var live: [MachineController] {
        var machines = MachineWindow.all.map(\.machine)
        for session in NetworkSession.open.values {
            for controller in session.controllers.values where !machines.contains(where: { $0 === controller }) {
                machines.append(controller)
            }
        }
        return machines
    }
    /// The machine whose window was last in front: where the Game Library
    /// plays a game.
    static weak var frontmost: MachineController?
    /// A game to start in the next machine window that opens (the Game
    /// Library, with no machine window open).
    static var pendingLaunch: ((MachineController) -> Void)?
    /// The game from My Games it's playing, if any.
    var playing: UUID?
    /// The Archimedes Classic it's playing, if any: its own machine (not
    /// the one in Preferences), started from a CMOS reset, with its discs.
    /// (Set by ClassicPlay.swift's play(_:…).)
    var session: GameSession?
    /// Which of the session's floppies is in drive 0.
    var sessionDisc = 0
    /// Whether the session still has its discs to hand (not after another
    /// disc's put in by hand).
    var sessionDiscsActive = false
    @ObservationIgnored let launcherBox = LauncherBox()
    @ObservationIgnored var launcherTimer: GLibTimer?
    /// Why the debugger has stopped the machine, if it has.
    private(set) var debugStop: String?
    @ObservationIgnored private var debugStopCount = 0
    /// An AI agent is holding the machine still between its tool calls.
    private(set) var heldForAgent = false
    /// This window's machine is the one agents attach to.
    var servesAgents = false
    /// The debugger's view of this machine.
    @ObservationIgnored private(set) lazy var debugger = DebuggerModel(machine: self)
    /// Set when the debugger stops the machine, so its window opens.
    var debuggerRequested = false
    /// Set to open the Disc Contents window, showing this drive.
    var discContentsRequested = false
    var discContentsDrive: DiscDrive?
    /// While the debugger is open, the screen address under the mouse.
    var inspecting = false { didSet { if !inspecting { inspection = nil } } }
    private(set) var inspection: String?
    /// Paused, or held still by an agent: Resume is what Pause offers.
    var isStill: Bool { paused || heldForAgent }

    @ObservationIgnored private var importedConfiguration: MachineConfiguration?
    @ObservationIgnored private var importedCMOSPath: String?

    init() {
        stationID = nil
    }

    // MARK: Network stations

    /// The network node this machine is, if it's a network's station.
    let stationID: UUID?
    var isStation: Bool { stationID != nil }
    @ObservationIgnored weak var owner: StationOwner?
    /// A server's console: its screen's last line, kept up to date.
    private(set) var consoleLine: String?
    @ObservationIgnored var watchesConsole = false
    @ObservationIgnored private var consoleTimer: GLibTimer?

    /// A network's station: `machine`, which its network runs (see
    /// `host`, which the network takes).
    init(station: UUID, machine m: Machine, cmosPath: String, romPath: String, hardDiscs: [String?], owner: StationOwner) {
        stationID = station
        self.owner = owner
        let c = m.configuration
        model = c.model; cpu = c.cpu; ramKB = c.ramKB; monitor = c.monitorType
        self.romPath = romPath; self.hardDiscs = hardDiscs
        romVersion = m.rom.versionString
        audio.muted = true
        host = EmulatorHost(machine: m, profile: .init(cmosPath: cmosPath), audioSink: tee, isStation: true)
        host?.agentRecording = host.map { agentRecordingHooks(host: $0) }
        lightsTimer = GLibTimer(interval: 1.0 / 15) { [weak self] in
            guard let self else { return false }
            self.poll()
            return true
        }
        consoleTimer = GLibTimer(interval: 1) { [weak self] in
            guard let self else { return false }
            self.readConsole()
            return true
        }
    }

    /// Switched off, or its network closed: it stops being shown.
    func detachFromNetwork() {
        if recorder != nil { toggleRecording() }
        lightsTimer?.invalidate()
        consoleTimer?.invalidate()
        audio.stop()
    }

    /// Whether this station's sound is heard (the one with the keyboard).
    func setAudible(_ on: Bool) {
        if on { audio.start() } else { audio.stop() }
        audio.muted = !on || muted
    }

    private func readConsole() {
        guard watchesConsole, let host else { return }
        host.send { [weak self] s in
            // The last line of text: in the desktop, rows of graphics read
            // as "?" and "_" (unknown glyphs) and are passed over.
            let line = s.machine.screenText.last { row in
                let shown = row.filter { $0 != " " }
                return !shown.isEmpty && shown.filter { $0.isLetter || $0.isNumber }.count * 2 >= shown.count
            }?.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async { if self?.consoleLine != line { self?.consoleLine = line } }
        }
    }

    private var parent: Widget? { window?.window ?? frontWindow }

    // MARK: Machine

    /// Everything that needs a new machine (a power cycle) to change.
    struct Hardware: Equatable {
        var model: MachineModel
        var cpu: CPUType
        var ramKB: Int
        var monitor: MonitorType
        var romPath: String
        var hardDiscs: [String?]
    }

    private func configuration(_ hw: Hardware, cmos: String) -> MachineConfiguration {
        var c = importedConfiguration ?? MachineConfiguration(model: hw.model)
        c.cpu = hw.cpu
        c.ramKB = hw.ramKB
        c.monitorType = hw.monitor
        c.romPaths = [hw.romPath]
        c.hardDiscs = hw.hardDiscs
        c.econetStation = owner?.stationNumber(self) ?? importedConfiguration?.econetStation
        c.cmosSettings = owner?.stationCMOSSettings(self) ?? importedConfiguration?.cmosSettings ?? []
        // First boot, or a CMOS RISC OS never set up (as a 16 MB A540's was
        // when Delete was let go too soon): Delete held resets it to defaults.
        // A Classic always starts from RISC OS's defaults.
        if importedConfiguration != nil {
            c.cmosPath = cmos
        } else if session == nil, let d = FileManager.default.contents(atPath: cmos), !Machine.cmosNeverConfigured([UInt8](d)) {
            c.cmosPath = cmos
        } else {
            c.powerOnKeys = [0x34]
        }
        return c
    }

    /// Builds a machine for `hw`. Hard discs whose files have gone are
    /// left out (and reported), rather than stopping the machine starting.
    private func makeMachine(_ hw: Hardware) throws -> (Machine, String, Hardware) {
        var hw = hw
        let missing = hw.hardDiscs.compactMap { $0 }.filter { !FileManager.default.fileExists(atPath: $0) }
        if !missing.isEmpty {
            hw.hardDiscs = hw.hardDiscs.map { p in p.flatMap { missing.contains($0) ? nil : $0 } }
            alert("A hard disc image is missing", "The machine starts without " + missing.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + ". Use Hard Disc ▸ Open to fit it again.")
        }
        let rom = try ROMImage.load(paths: [hw.romPath])
        let cmos = owner?.stationCMOSPath(self) ?? session?.cmosPath ?? importedCMOSPath ?? AppSettings.cmosPath(for: rom, model: hw.model)
        return (try Machine(configuration: configuration(hw, cmos: cmos), rom: rom), cmos, hw)
    }

    private var hardware: Hardware? {
        romPath.map { Hardware(model: model, cpu: cpu, ramKB: ramKB, monitor: monitor, romPath: $0, hardDiscs: hardDiscs) }
    }

    private func adopt(_ hw: Hardware) {
        model = hw.model; cpu = hw.cpu; ramKB = hw.ramKB; monitor = hw.monitor; romPath = hw.romPath; hardDiscs = hw.hardDiscs
        if let owner {
            owner.stationSetupChanged(self)
            return
        }
        // A Classic's machine is its own: Preferences keep the user's.
        if session != nil { return }
        let s = AppSettings.shared
        s.model = hw.model; s.romPath = hw.romPath
        s.setCPU(hw.cpu, for: hw.model); s.setRAMKB(hw.ramKB, for: hw.model); s.setHardDiscs(hw.hardDiscs, for: hw.model)
        s.setMonitor(hw.monitor, for: hw.model)
    }

    /// Starts the first machine (or restarts after a failed start).
    func start(romPath path: String) {
        do {
            let (m, cmos, hw) = try makeMachine(Hardware(model: model, cpu: cpu, ramKB: ramKB, monitor: monitor, romPath: path, hardDiscs: hardDiscs))
            let h = EmulatorHost(machine: m, profile: .init(cmosPath: cmos), audioSink: tee,
                                 drivesHeard: AppSettings.shared.discDriveSounds)
            host = h
            adopt(hw)
            romVersion = m.rom.versionString
            startError = nil
            audio.muted = muted
            audio.start()
            h.start()
            h.agentRecording = agentRecordingHooks(host: h)
            AppAgentContext.startServer(for: h, controller: self)
            lightsTimer = GLibTimer(interval: 1.0 / 15) { [weak self] in
                guard let self else { return false }
                self.poll()
                return true
            }
            if let p = ProcessInfo.processInfo.environment["LINUXARCH_LOAD_STATE"] { loadState(URL(fileURLWithPath: p)) }
        } catch {
            startError = "\(error)"
        }
    }

    /// The window's closing: stops the machine.
    func shutdown() {
        if recorder != nil { toggleRecording() }
        if let host { AppAgentContext.machineClosed(host) }
        host?.stop()
        audio.stop()
        lightsTimer?.invalidate()
    }

    private func poll() {
        guard let host else { return }
        let l = host.lights
        if l != lights { lights = l }
        let d = host.disc
        if d != disc { disc = d }
        // A loaded state can change the disc behind the menus.
        if d.name != discName && !discIsUntitled { discName = d.name }
        // A breakpoint pauses the machine on the emulation thread.
        let stop = host.debugStop, count = host.debugStopCount
        // A new stop (a breakpoint, a step, an agent) brings the debugger forward.
        if stop != debugStop || count != debugStopCount {
            debugStop = stop
            if stop != nil && count != debugStopCount { debuggerRequested = true; debugger.refresh() }
            debugStopCount = count
        }
        let held = host.heldForAgent
        if held != heldForAgent { heldForAgent = held }
        if host.paused != paused { paused = host.paused }
    }

    // MARK: Portable machine configuration

    func chooseImportConfiguration() {
        guard !isStation else { return }
        FileDialogs.open(parent: parent, title: "Import Machine Configuration",
                         filters: [.init(name: "Machine configurations", suffixes: ["json"])]) { url in
            Task { @MainActor in
                do { try await self.importConfiguration(from: url, confirmRestart: true) }
                catch { self.alert("Could not import machine configuration", "\(error)") }
            }
        }
    }

    func importConfiguration(from url: URL, confirmRestart: Bool) async throws {
        guard !isStation else { throw MachineError.badConfiguration("Use the network configuration for network stations") }
        var c = try MachineConfigurationFile.load(from: url)
        let rom = try ROMImage.load(paths: c.romPaths)
        // Construct before changing the current session, including opening its discs.
        _ = try Machine(configuration: c, rom: rom)
        if confirmRestart && host != nil {
            guard await Alerts.confirm("Restart with the imported configuration?",
                                       "\(c.model.displayName), \(c.cpu.displayName), \(c.ramKB) KB. The current running session will be replaced.",
                                       button: "Import and Restart", parent: parent) else { return }
            guard await confirmDiscChanges(before: "importing a machine configuration") else { return }
        }
        syncHardDiscs()
        // Consolidate chip sets using the existing ROM library importer.
        let installed = try ROMImporter.install(rom, into: ROMLibrary.directory)
        c.romPaths = [installed]
        let profile = URL(fileURLWithPath: AppSettings.supportDirectory).appendingPathComponent("Profiles/Imported-\(UUID().uuidString).cmos")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let source = c.cmosPath { try Data(contentsOf: URL(fileURLWithPath: source)).write(to: profile, options: .atomic) }
        c.cmosPath = FileManager.default.fileExists(atPath: profile.path) ? profile.path : nil
        let m = try Machine(configuration: c, rom: rom)
        // Seed the private profile even when the input has no CMOS sidecar.
        try Data(m.cmos).write(to: profile, options: .atomic)
        stopRecordingIfNeeded(); endSession()
        importedConfiguration = c; importedCMOSPath = profile.path
        let hw = Hardware(model: c.model, cpu: c.cpu, ramKB: c.ramKB, monitor: c.monitorType, romPath: installed, hardDiscs: c.hardDiscs)
        AppSettings.shared.addROM(installed)
        adopt(hw); romVersion = rom.versionString; startError = nil
        if let host {
            host.send { s in
                s.host.saveCMOSIfChanged()
                s.host.changeProfile(.init(cmosPath: profile.path))
                s.replace(with: m); m.powerOn()
                s.host.setPersistCMOS(true, session: s)
            }
        } else {
            start(romPath: installed)
        }
    }

    func chooseExportConfiguration() {
        guard !isStation, host != nil else { return }
        FileDialogs.save(parent: parent, title: "Export Machine Configuration", name: "LinuxArch.machine.json",
                         filters: [.init(name: "Machine configurations", suffixes: ["json"])]) { url in
            Task { @MainActor in
                do {
                    try await self.exportConfiguration(to: url)
                    self.show("Configuration exported")
                } catch { self.alert("Could not export machine configuration", "\(error)") }
            }
        }
    }

    func exportConfiguration(to url: URL) async throws {
        guard let host else { throw MachineError.badConfiguration("No running machine to export") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            host.send { s in
                do {
                    try MachineConfigurationFile.save(s.machine.configuration, cmos: s.machine.cmos, to: url)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Changes the model, processor, memory, ROM or hard discs: a new
    /// machine, power cycled, with the floppy kept. A new model brings back
    /// the processor, memory and hard discs it last had.
    func setHardware(model newModel: MachineModel? = nil, cpu newCPU: CPUType? = nil, ramKB newRAM: Int? = nil,
                     monitor newMonitor: MonitorType? = nil, romPath newROM: String? = nil, hardDiscs newDiscs: [String?]? = nil,
                     reload: Bool = false, keepingSession: Bool = false) {
        var reload = reload
        if session != nil && !keepingSession {
            // A change made by hand ends a Classic: back to the user's own
            // machine (as Preferences have it), with the change.
            endSession()
            let s = AppSettings.shared
            model = s.model; cpu = s.cpu(for: s.model); ramKB = s.ramKB(for: s.model); monitor = s.monitor(for: s.model)
            hardDiscs = s.hardDiscs(for: s.model)
            if let rom = s.romPath { romPath = rom }
            reload = true
        }
        var hw = Hardware(model: model, cpu: cpu, ramKB: ramKB, monitor: monitor, romPath: romPath ?? "", hardDiscs: hardDiscs)
        if let newModel, newModel != hw.model, isStation {
            hw = Hardware(model: newModel, cpu: newModel.defaultCPU, ramKB: newModel.defaultRAMKB, monitor: .standard,
                          romPath: hw.romPath, hardDiscs: [])
        } else if let newModel, newModel != hw.model {
            let s = AppSettings.shared
            // A ROM that can't drive the new model gives way to one that can
            // (ArcLibre's 2 MB and 4 MB ROMs, or RISC OS 2 for 3).
            let fits = s.romLibrary.first { $0.path == hw.romPath }?.suits(newModel) ?? true
            hw = Hardware(model: newModel, cpu: s.cpu(for: newModel), ramKB: s.ramKB(for: newModel), monitor: s.monitor(for: newModel),
                          romPath: fits || newROM != nil ? hw.romPath : s.preferredROM(for: newModel, like: hw.romPath) ?? hw.romPath,
                          hardDiscs: s.hardDiscs(for: newModel))
        }
        if let newCPU { hw.cpu = newCPU }
        if let newMonitor { hw.monitor = newMonitor }
        if let newRAM { hw.ramKB = newRAM }
        if let newROM { hw.romPath = newROM }
        if let newDiscs { hw.hardDiscs = newDiscs }
        if let owner, hw.hardDiscs != hardDiscs { hw.hardDiscs = owner.station(self, willFitHardDiscs: hw.hardDiscs) }
        guard reload || hw != hardware || host == nil else { return }
        guard let host else {
            // No machine yet: remember the choice, and start if there is a ROM.
            if hw.romPath.isEmpty {
                model = hw.model; cpu = hw.cpu; ramKB = hw.ramKB; monitor = hw.monitor; hardDiscs = hw.hardDiscs
            } else {
                adopt(hw); start(romPath: hw.romPath)
            }
            return
        }
        if reload || hw.hardDiscs != hardDiscs || hw.model != model { syncHardDiscs() }
        do {
            let (m, cmos, fitted) = try makeMachine(hw)
            stopRecordingIfNeeded()
            adopt(fitted)
            romVersion = m.rom.versionString
            host.send { s in
                if let disc = s.machine.fdc.drives[0].disc { m.insertFloppy(disc) }
                s.host.changeProfile(.init(cmosPath: cmos))
                s.replace(with: m)
                m.powerOn()
                s.host.setPersistCMOS(true, session: s)
            }
        } catch {
            alert("Could not set up the \(hw.model.displayName)", "\(error)")
        }
    }

    func powerCycle() {
        stopRecordingIfNeeded()
        host?.send { s in
            s.host.restoreProfileCMOS(into: s.machine)
            s.machine.powerOn()
            s.rewinder.reset()
        }
    }

    /// The reset button: restarts the OS, keeping memory, CMOS and the disc.
    func reset() { host?.send { $0.machine.reset() } }

    func togglePause() {
        // Resume lets go of an agent's hold first.
        if heldForAgent && !paused { host?.heldForAgent = false; heldForAgent = false; return }
        paused.toggle()
        host?.paused = paused
    }

    func setPaused(_ value: Bool) {
        paused = value
        host?.paused = value
    }

    func toggleSpeedLimit() {
        speedLimited.toggle()
        host?.speedLimited = speedLimited
    }

    // MARK: Input

    func keyDown(_ code: UInt8) { host?.send { $0.machine.keyDown(code) } }
    func keyUp(_ code: UInt8) { host?.send { $0.machine.keyUp(code) } }
    func mouseMove(dx: Int, dy: Int) { host?.send { $0.machine.mouseMove(dx: dx, dy: dy) } }
    /// Following the desktop's pointer: where RISC OS's should go (frame
    /// pixels, or nil to leave it), and how far the desktop's moved, for
    /// programs that turn RISC OS's off and read the mouse themselves.
    func followPointer(to target: (x: Int, y: Int)?, dx: Int = 0, dy: Int = 0) {
        host?.send { s in
            s.pointerFollower.target = target
            s.pointerFollower.moveBy(dx: dx, dy: dy, in: s.machine)
        }
    }
    func releaseAllKeys() { host?.send { $0.machine.keyboard.releaseAll(); $0.machine.ioc.pumpKeyboard() } }

    /// Types the clipboard's text into the machine.
    func pasteText() {
        Clipboard.readText { [weak self] text in
            guard let text else { return }
            self?.type(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        }
    }

    /// Types text into the machine as key presses.
    func type(_ text: String) {
        host?.send { $0.machine.scheduleTyping(text, intervalMs: 40) }
    }

    func toggleMouseCapture() {
        window?.emulator.toggleMouseCapture()
    }

    // MARK: Discs

    static let discFilter = FileDialogs.Filter(name: "Floppy disc images", suffixes: ["adf", "adl", "adm", "ads", "jfd", "hfe"])

    func openDisc() {
        FileDialogs.open(parent: parent, title: "Open Disc", filters: [Self.discFilter]) { url in
            Task { @MainActor in await self.insertDisc(url) }
        }
    }

    /// Puts the image in drive 0. Writes stay in memory; the file is never changed.
    func insertDisc(_ url: URL) async {
        guard await confirmDiscChanges(before: "inserting another disc") else { return }
        stopSessionDiscs()
        var url = url
        if let owner {
            guard let copy = owner.station(self, willInsert: url, drive: 0) else { return }
            url = copy
        }
        do {
            let img = try FloppyImage.open(path: url.path)
            host?.send { $0.machine.insertFloppy(img) }
            discName = url.lastPathComponent
            discIsUntitled = false
            AppSettings.shared.addRecent(url.path)
            noteRecentFile(url)
        } catch {
            alert("Could not open \(url.lastPathComponent)", "\(error)")
        }
    }

    /// A disc the network put in drive 0 when it started the machine.
    func noteNetworkDisc(_ name: String) { discName = name }

    /// A disc put in drive 0 for the user (a game from the library).
    func noteDisc(_ url: URL) {
        discName = url.lastPathComponent
        discIsUntitled = false
    }

    /// Puts a newly formatted disc in drive 0, to be saved somewhere later.
    func insertBlankDisc(_ format: ADFSFloppyFormatter.Format) async {
        guard await confirmDiscChanges(before: "inserting another disc") else { return }
        stopSessionDiscs()
        let img = FloppyImage.blank(format, name: "Untitled")
        host?.send { $0.machine.insertFloppy(img) }
        discName = "Untitled"
        discIsUntitled = true
    }

    func ejectDisc() async {
        guard await confirmDiscChanges(before: "ejecting it") else { return }
        stopSessionDiscs()
        host?.send { $0.machine.ejectFloppy() }
        discName = nil
        discIsUntitled = false
        owner?.station(self, didEject: 0)
    }

    /// Writes drive 0's changes back to its image file (or to `url`).
    @discardableResult
    func saveDisc(to url: URL? = nil) async -> Bool {
        guard let host else { return false }
        // A new disc has nowhere to go back to.
        if url == nil && discIsUntitled { return await saveDiscAs() }
        let error: Error? = host.sendAndWait { s in
            guard let image = s.machine.fdc.drives[0].disc else { return nil }
            do {
                try image.saveChanges(to: url?.path)
                // History points refer to the disc as it was; start afresh.
                s.rewinder.reset()
                return nil
            } catch { return error }
        }
        if let error {
            alert("Could not save the disc", "\(error)")
            return false
        }
        if let url {
            discName = url.lastPathComponent
            discIsUntitled = false
            AppSettings.shared.addRecent(url.path)
            noteRecentFile(url)
        }
        disc.modified = false
        show("Disc saved")
        return true
    }

    @discardableResult
    func saveDiscAs() async -> Bool {
        let ext = disc.fileExtension
        let name = (discIsUntitled ? "Untitled" : discName.map { ($0 as NSString).deletingPathExtension + " copy" } ?? "Disc") + "." + ext
        let url: URL? = await withCheckedContinuation { continuation in
            var resumed = false
            FileDialogs.save(parent: parent, title: "Save Disc As", name: name,
                             filters: [.init(name: "\(ext.uppercased()) images", suffixes: [ext])]) { url in
                resumed = true
                continuation.resume(returning: url)
            } cancelled: {
                if !resumed { continuation.resume(returning: nil) }
            }
        }
        guard let url else { return false }
        return await saveDisc(to: url)
    }

    /// Before the disc's changes would be lost: offers to save them. Returns
    /// false if the user cancels.
    func confirmDiscChanges(before action: String) async -> Bool {
        guard let host, host.disc.modified, let name = discName else { return true }
        if host.disc.savable {
            let info = discIsUntitled ? "It's a new disc, only in memory." : "The changes are only in memory; the image file has not been changed."
            let response = await Alerts.choice("Save the changes to \(name) before \(action)?", info,
                                               responses: [("cancel", "Cancel"), ("discard", "Don’t Save"), ("save", "Save")],
                                               destructive: "discard", parent: parent)
            switch response {
            case "save": return await saveDisc()
            case "discard": return true
            default: return false
            }
        } else {
            return await Alerts.confirm("Save the changes to \(name) before \(action)?",
                                        "JFD and HFE images are kept read-only, so these changes cannot be written back. Save the machine's state to keep them.",
                                        button: "Discard Changes", destructive: true, parent: parent)
        }
    }

    /// Opens whatever was dropped on the window or opened from the file
    /// manager.
    func open(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case NetworkPackage.fileExtension: NetworkStudioWindow.show(url)
        case Self.stateExtension: loadState(url)
        case "bas" where host != nil: runBASICProgram(url)
        default:
            Task { @MainActor in
                // Before a machine is running, anything dropped is offered as ROMs.
                if host == nil {
                    await ROMLibrary.shared.add([url])
                    ROMLibrary.shared.report(parent: parent)
                    if host == nil, let rom = AppSettings.shared.romPath { start(romPath: rom) }
                    return
                }
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue, let d = FileManager.default.contents(atPath: url.path), MediaDetector.detect([UInt8](d)).format != "unknown" {
                    await insertDisc(url)
                    return
                }
                // Not a disc: perhaps ROMs (a ROM image, chips, a folder or a ZIP).
                let added = await ROMLibrary.shared.add([url])
                if added.isEmpty, url.pathExtension.lowercased() == "zip" || isDir.boolValue {
                    await offerFilesForHardDisc([url])
                } else if added.isEmpty {
                    alert("LinuxArch can't open \(url.lastPathComponent)", "It isn't a floppy disc image, a saved state or a RISC OS ROM.")
                } else {
                    let names = added.map(\.found.rom.versionString).joined(separator: ", ")
                    alert("Added to your ROMs", "\(names). Choose it from Machine ▸ ROM to use it in this window.")
                }
            }
        }
    }

    /// A BASIC program file (text or tokenised), dropped or opened: loaded
    /// at PAGE and RUN, as CHAIN would, if BASIC is at its prompt.
    func runBASICProgram(_ url: URL) {
        guard let host else { return }
        let program: [UInt8]
        do {
            program = try BasicDebugger.program(fromFile: [UInt8](Data(contentsOf: url)))
        } catch {
            alert("Can’t run \(url.lastPathComponent)", "\(error)")
            return
        }
        let problem: String? = host.sendAndWait { s in
            do {
                try s.machine.debugger.basic.loadAtPrompt(program)
                s.machine.scheduleTyping("RUN\n", intervalMs: 40)
                return nil
            } catch {
                return "\(error)"
            }
        }
        if let problem {
            alert("Can’t run \(url.lastPathComponent)", problem.prefix(1).uppercased() + problem.dropFirst() + ".")
        } else {
            noteRecentFile(url)
        }
    }

    // MARK: Hard discs

    static let hardDiscFilter = FileDialogs.Filter(name: "Hard disc images", suffixes: ["hdf"])

    /// Pushes written sectors to the image files (before they are reopened).
    func syncHardDiscs() {
        host?.sendAndWait { s in s.machine.hdc?.drives.forEach { $0?.synchronize() } }
    }

    func hardDiscName(_ drive: Int) -> String? {
        hardDiscs.indices.contains(drive) ? hardDiscs[drive].map { ($0 as NSString).lastPathComponent } : nil
    }

    /// Another window's machine using `path` would corrupt it.
    private func inUseElsewhere(_ path: String) -> Bool {
        Self.live.contains { $0 !== self && $0.hardDiscs.contains(path) }
    }

    private func fitHardDisc(_ path: String?, drive: Int) {
        var discs = hardDiscs
        while discs.count < model.hardDiscSlots { discs.append(nil) }
        guard discs.indices.contains(drive) else { return }
        discs[drive] = path
        setHardware(hardDiscs: discs)
    }

    /// Fits an existing image (power cycles).
    func openHardDisc(drive: Int) {
        let kind = model.hasIDE ? "IDE" : "ST506"
        FileDialogs.open(parent: parent, title: "Open \(kind) Hard Disc for Drive \(drive + 4)", filters: [Self.hardDiscFilter]) { url in
            Task { @MainActor in await self.openHardDisc(url, drive: drive) }
        }
    }

    func openHardDisc(_ url: URL, drive: Int) async {
        guard !inUseElsewhere(url.path) else {
            alert("\(url.lastPathComponent) is in use", "Another window's machine has this hard disc fitted. Remove it there first.")
            return
        }
        if let other = try? ADFSHardDiscWriter.usage(path: url.path), other.geometry.sectorSize != model.hardDiscSectorSize {
            if let copy = await offerCopyForThisMachine(url, usage: other) { fitHardDisc(copy.path, drive: drive) }
            return
        }
        do { _ = try HardDiscImage.open(path: url.path, sectorSize: model.hardDiscSectorSize) } catch {
            alert("Could not use \(url.lastPathComponent)", "\(error)")
            return
        }
        fitHardDisc(url.path, drive: drive)
    }

    /// An ST506 drive on an IDE machine, or the other way round: the sector
    /// sizes differ, so offer a copy of its files on a new drive of the
    /// right kind, beside it. Returns the copy.
    private func offerCopyForThisMachine(_ url: URL, usage: ADFSHardDiscWriter.Usage) async -> URL? {
        let (kind, other) = model.hasIDE ? ("IDE", "ST506") : ("ST506", "IDE")
        let presets = model.hasIDE ? HardDiscGeometry.idePresets : HardDiscGeometry.presets
        let needed = usage.compactedEnd + 0x10000
        guard let geometry = presets.first(where: { $0.geometry.byteCount >= needed })?.geometry else {
            alert("\(url.lastPathComponent) is an \(other) drive", "The \(model.displayName) takes \(kind) drives, and its files (\(needed / 1_048_576) MB) are too big for the largest \(kind) drive LinuxArch makes.")
            return nil
        }
        let base = url.deletingPathExtension().lastPathComponent
        var copy = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(kind)).hdf")
        var n = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(kind) \(n)).hdf")
            n += 1
        }
        guard await Alerts.confirm("\(url.lastPathComponent) is an \(other) drive",
                                   "The \(model.displayName) takes \(kind) drives, which have a different sector size. LinuxArch can copy its files onto a new \(Int(geometry.megabytes.rounded())) MB \(kind) drive, “\(copy.lastPathComponent)”, and fit that instead. The original is left as it is.",
                                   button: "Make \(kind) Copy", parent: parent) else { return nil }
        do { try ADFSHardDiscWriter.copy(from: url.path, to: copy.path, geometry: geometry) } catch {
            try? FileManager.default.removeItem(at: copy)
            alert("Could not copy \(url.lastPathComponent)", "\(error)")
            return nil
        }
        return copy
    }

    /// Asks how big a drive it is (the smallest that holds `minimumBytes`
    /// is chosen to begin with), then where to save it.
    private func chooseNewHardDisc(drive: Int, heading: String, message: String, minimumBytes: Int = 0) async -> (URL, HardDiscGeometry)? {
        let presets = model.hasIDE ? HardDiscGeometry.idePresets : HardDiscGeometry.presets
        let initial = presets.firstIndex { $0.geometry.byteCount >= minimumBytes } ?? presets.count - 1
        guard let index = await Alerts.chooseItem(heading, message, items: presets.map(\.name), selected: initial,
                                                  button: "Choose Where…", parent: parent) else { return nil }
        try? FileManager.default.createDirectory(atPath: AppSettings.hardDiscDirectory, withIntermediateDirectories: true)
        let url: URL? = await withCheckedContinuation { continuation in
            var resumed = false
            FileDialogs.save(parent: parent, title: heading, name: "Hard Disc \(drive + 4).hdf", filters: [Self.hardDiscFilter],
                             folder: URL(fileURLWithPath: AppSettings.hardDiscDirectory)) { url in
                resumed = true
                continuation.resume(returning: url)
            } cancelled: {
                if !resumed { continuation.resume(returning: nil) }
            }
        }
        return url.map { ($0, presets[index].geometry) }
    }

    /// Creates a formatted image of a chosen size and fits it (power cycles).
    func newHardDisc(drive: Int) async {
        guard let (url, geometry) = await chooseNewHardDisc(drive: drive, heading: "New Hard Disc",
                                                            message: "A new hard disc, formatted and empty, for drive \(drive + 4). The machine will be power cycled.") else { return }
        do {
            // With !System (for installers that put modules in System:Modules) and !Scrap, as on Acorn's RISC OS 3.1 hard discs.
            try ADFSFormatter.createFormattedImage(path: url.path, geometry: geometry, name: (url.lastPathComponent as NSString).deletingPathExtension, system: true)
        } catch {
            alert("Could not create the hard disc", "\(error)")
            return
        }
        fitHardDisc(url.path, drive: drive)
    }

    /// Asks for ZIP archives and ADFS floppies (folders can be dropped).
    private func chooseFileSources(_ title: String) async -> [URL] {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileDialogs.openMultiple(parent: parent, title: title,
                                     filters: [.init(name: "ZIP archives and floppy images", suffixes: ["zip"] + Self.discFilter.suffixes)]) { urls in
                resumed = true
                continuation.resume(returning: urls)
            } cancelled: {
                if !resumed { continuation.resume(returning: []) }
            }
        }
    }

    /// The files from each source, merged (later sources win).
    private func items(from sources: [URL]) -> [ADFSHardDiscBuilder.Item]? {
        var items: [ADFSHardDiscBuilder.Item] = []
        for source in sources {
            do { items += try ADFSHardDiscBuilder.items(from: source.path) } catch {
                alert("Could not read \(source.lastPathComponent)", "\(error)")
                return nil
            }
        }
        var seen: Set<String> = []
        return items.reversed().filter { seen.insert($0.path.joined(separator: ".").uppercased()).inserted }.reversed()
    }

    private static func describe(_ sources: [URL]) -> String {
        sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) sources"
    }

    /// Creates a hard disc holding the files from ZIP archives or folders
    /// (software that came as files rather than discs), and fits it.
    func newHardDiscFromFiles(drive: Int, sources given: [URL]? = nil) async {
        var sources = given ?? []
        if given == nil { sources = await chooseFileSources("Files for a New Hard Disc") }
        guard !sources.isEmpty, let items = items(from: sources) else { return }
        let needed = items.reduce(0x10000) { $0 + $1.data.count + 2048 }
        guard let (url, geometry) = await chooseNewHardDisc(drive: drive, heading: "New Hard Disc from Files",
                                                            message: "A new hard disc holding the \(items.count) files from \(Self.describe(sources)), for drive \(drive + 4). The machine will be power cycled.",
                                                            minimumBytes: needed) else { return }
        do {
            let (files, directories) = ADFSFormatter.withSystem(items)
            try ADFSHardDiscBuilder.create(path: url.path, geometry: geometry, name: (url.lastPathComponent as NSString).deletingPathExtension,
                                           items: files, directories: directories)
        } catch {
            try? FileManager.default.removeItem(at: url)
            alert("Could not create the hard disc", "\(error)")
            return
        }
        fitHardDisc(url.path, drive: drive)
    }

    /// Copies the files from ZIP archives or folders onto the drive's disc,
    /// alongside what is there (power cycles, as RISC OS keeps the drive's
    /// map and directories in memory).
    func addFilesToHardDisc(drive: Int, sources given: [URL]? = nil) async {
        guard hardDiscs.indices.contains(drive), let path = hardDiscs[drive] else { return }
        let name = (path as NSString).lastPathComponent
        var sources = given ?? []
        if given == nil { sources = await chooseFileSources("Add Files to \(name)") }
        guard !sources.isEmpty, let items = items(from: sources) else { return }
        var plan: ADFSHardDiscWriter.Summary
        var compact = false
        do { plan = try ADFSHardDiscWriter.plan(path: path, items: items) } catch let e as ADFSHardDiscWriter.WriteError where e.isFragmented {
            // There is room, but split between gaps: offer to close them up.
            guard await Alerts.confirm("\(name) has room, but not in one piece",
                                       "\(e)\n\nLinuxArch can compact the drive first, as *Compact does: files move to close the gaps, and the free space becomes one area. It works on a copy, so the drive is unchanged if anything goes wrong.",
                                       button: "Compact and Continue", parent: parent) else { return }
            do { plan = try ADFSHardDiscWriter.plan(path: path, items: items, compact: true) } catch {
                alert("Could not add the files to \(name)", "\(error)")
                return
            }
            compact = true
        } catch {
            alert("Could not add the files to \(name)", "\(error)")
            return
        }
        var info = "The machine will be restarted so RISC OS sees them."
        if !plan.replaced.isEmpty {
            let shown = plan.replaced.prefix(6).map { "$." + $0 }.joined(separator: "\n")
            info = "\(plan.replaced.count) files already on the disc will be replaced:\n\(shown)" + (plan.replaced.count > 6 ? "\n…" : "") + "\n\n" + info
        }
        if compact { info = "The drive will be compacted first (\(plan.bytesMoved / 1024) KB moved). " + info }
        guard await Alerts.confirm("Add \(items.count) files from \(Self.describe(sources)) to \(name)?",
                                   info + " \(plan.bytesFree / 1024) KB will be left free.",
                                   button: plan.replaced.isEmpty ? "Add" : "Replace", parent: parent) else { return }
        // Stop the running machine writing to the drive behind the change.
        host?.sendAndWait { s in s.machine.hdc?.drives.forEach { $0?.synchronize(); $0?.suppressWrites = true } }
        do { try ADFSHardDiscWriter.add(path: path, items: items, compact: compact) } catch {
            host?.sendAndWait { s in s.machine.hdc?.drives.forEach { $0?.suppressWrites = false } }
            alert("Could not add the files to \(name)", "\(error)")
            return
        }
        setHardware(hardDiscs: hardDiscs, reload: true)
    }

    /// Makes the drive's disc bigger or smaller, choosing from the sizes New
    /// Hard Disc offers (power cycles). Shrinking offers to compact first
    /// when files lie past the new end.
    func resizeHardDisc(drive: Int) async {
        guard hardDiscs.indices.contains(drive), let path = hardDiscs[drive] else { return }
        let name = (path as NSString).lastPathComponent
        guard !inUseElsewhere(path) else {
            alert("\(name) is in use", "Another window's machine has this hard disc fitted. Remove it there first.")
            return
        }
        syncHardDiscs()
        let usage: ADFSHardDiscWriter.Usage
        do { usage = try ADFSHardDiscWriter.usage(path: path) } catch {
            alert("Could not resize \(name)", "\(error)")
            return
        }
        func mb(_ n: Int) -> String { String(format: "%.1f MB", Double(n) / 1_048_576) }
        let presets = (usage.geometry.sectorSize == 256 ? HardDiscGeometry.presets : HardDiscGeometry.idePresets)
            .filter { $0.geometry != usage.geometry }
        guard !presets.isEmpty,
              let index = await Alerts.chooseItem("Resize \(name)",
                                                  "It's \(mb(usage.size)), with \(mb(usage.size - usage.bytesFree)) in use. Files stay where they are; the machine will be restarted.",
                                                  items: presets.map(\.name), selected: presets.firstIndex { $0.geometry.byteCount > usage.size } ?? 0,
                                                  button: "Resize", parent: parent) else { return }
        let target = presets[index].geometry

        var compact = false
        if target.byteCount < usage.usedEnd {
            guard usage.compactedEnd <= target.byteCount else {
                alert("\(name) won't fit in \(mb(target.byteCount))", "Its files need \(mb(usage.compactedEnd)) even when compacted.")
                return
            }
            guard await Alerts.confirm("Compact \(name) first?",
                                       "Files reach \(mb(usage.usedEnd)) into the drive. Compacting it, as *Compact does, moves them together so they fit in \(mb(target.byteCount)).",
                                       button: "Compact and Resize", parent: parent) else { return }
            compact = true
        }
        // Stop the running machine writing to the drive behind the change.
        host?.sendAndWait { s in s.machine.hdc?.drives.forEach { $0?.synchronize(); $0?.suppressWrites = true } }
        do { try ADFSHardDiscWriter.resize(path: path, to: target, compact: compact) } catch {
            host?.sendAndWait { s in s.machine.hdc?.drives.forEach { $0?.suppressWrites = false } }
            alert("Could not resize \(name)", "\(error)")
            return
        }
        setHardware(hardDiscs: hardDiscs, reload: true)
    }

    /// Dropped archives or folders that aren't ROMs: offered to a fitted
    /// hard disc, or as a new one.
    func offerFilesForHardDisc(_ sources: [URL]) async {
        let fitted = hardDiscs.indices.filter { hardDiscs[$0] != nil }
        guard model.hardDiscSlots > 0 else {
            alert("LinuxArch can't open \(Self.describe(sources))", "The \(model.displayName) has no hard disc to copy files onto. Choose a machine with one from the Machine menu.")
            return
        }
        var responses = [("cancel", "Cancel"), ("new", "New Hard Disc…")]
        for d in fitted { responses.append(("\(d)", "Add to \(hardDiscName(d) ?? "Drive :\(d + 4)")")) }
        let choice = await Alerts.choice("Copy the files from \(Self.describe(sources)) onto a hard disc?",
                                         "RISC OS software that comes as files rather than disc images runs from a hard disc.",
                                         responses: responses, parent: parent)
        if let drive = Int(choice) {
            await addFilesToHardDisc(drive: drive, sources: sources)
        } else if choice == "new" {
            await newHardDiscFromFiles(drive: (0..<model.hardDiscSlots).first { hardDiscs.indices.contains($0) ? hardDiscs[$0] == nil : true } ?? 0, sources: sources)
        }
    }

    /// Takes the drive out (power cycles). The image file keeps its contents.
    func ejectHardDisc(drive: Int) {
        fitHardDisc(nil, drive: drive)
    }

    // MARK: Screenshots

    private func screenshotPNG() -> Data? {
        guard let f = host?.frame, f.width > 1 else { return nil }
        return Data(PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY))
    }

    func saveScreenshot() {
        guard let png = screenshotPNG() else { return }
        FileDialogs.save(parent: parent, title: "Save Screenshot", name: FileDialogs.timestampedName("png"),
                         filters: [.init(name: "PNG images", suffixes: ["png"])]) { url in
            do { try png.write(to: url) } catch { self.alert("Could not save the screenshot", error.localizedDescription) }
        }
    }

    func copyScreenshot() {
        guard let png = screenshotPNG() else { return }
        Clipboard.setPNG(png)
        show("Screenshot copied")
    }

    // MARK: Recording

    private(set) var recordingURL: URL?
    @ObservationIgnored private var recorder: VideoRecorder?

    static let movieFilters = [FileDialogs.Filter(name: "MP4 movies (H.264)", suffixes: ["mp4"]),
                               FileDialogs.Filter(name: "QuickTime movies (ProRes)", suffixes: ["mov"])]

    /// Starts recording to a movie the user picks, or stops.
    func toggleRecording() {
        if let recorder {
            host?.frameTap = nil
            tee.recorder = nil
            self.recorder = nil
            recordingURL = nil
            recorder.finish { error in
                guard let error else { return }
                Task { @MainActor in self.alert("The recording could not be finished", error.localizedDescription) }
            }
            return
        }
        // (MP4 records H.264; MOV records ProRes.)
        FileDialogs.save(parent: parent, title: "Start Recording", name: FileDialogs.timestampedName("mp4"),
                         filters: Self.movieFilters) { url in
            self.startRecording(to: url)
        }
    }

    func startRecording(to url: URL) {
        guard let host, recorder == nil else { return }
        do {
            let r = try VideoRecorder(url: url, codec: url.pathExtension.lowercased() == "mov" ? .proRes : .h264)
            recorder = r
            recordingURL = url
            tee.recorder = r
            host.frameTap = { frame, ticks in r.addFrame(frame, ticks: ticks) }
        } catch {
            alert("Could not start recording", error.localizedDescription)
        }
    }

    /// Recordings follow guest time, which a load or rewind makes jump.
    private func stopRecordingIfNeeded() {
        if recorder != nil { toggleRecording() }
    }

    /// Recording for agents, run on the emulation thread; the window
    /// learns of it afterwards.
    private func agentRecordingHooks(host h: EmulatorHost) -> AgentRecordingHooks {
        let tee = self.tee
        let lock = NSLock()
        nonisolated(unsafe) var current: VideoRecorder?
        return AgentRecordingHooks(start: { [weak self, weak h] url in
            lock.lock(); defer { lock.unlock() }
            guard current == nil else { throw DebuggerError("already recording") }
            let r = try VideoRecorder(url: url, codec: url.pathExtension.lowercased() == "mov" ? .proRes : .h264)
            current = r
            tee.recorder = r
            h?.frameTap = { frame, ticks in r.addFrame(frame, ticks: ticks) }
            Task { @MainActor in self?.adoptRecording(r, url) }
        }, stop: { [weak self] in
            lock.lock(); defer { lock.unlock() }
            guard current != nil else { return false }
            current = nil
            Task { @MainActor in self?.toggleRecording() }
            return true
        }, isRecording: { lock.lock(); defer { lock.unlock() }; return current != nil })
    }

    private func adoptRecording(_ r: VideoRecorder, _ url: URL) {
        recorder = r
        recordingURL = url
    }

    // MARK: Save states

    static let stateExtension = "macarchstate"
    static let stateFilter = FileDialogs.Filter(name: "MacArch states", suffixes: [stateExtension])

    static var quickStateURL: URL {
        URL(fileURLWithPath: (AppSettings.supportDirectory as NSString).appendingPathComponent("Snapshots/quick.\(stateExtension)"))
    }

    func saveState() {
        let base = discName.map { ($0 as NSString).deletingPathExtension } ?? "Archimedes"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        FileDialogs.save(parent: parent, title: "Save State", name: "\(base) \(formatter.string(from: Date())).\(Self.stateExtension)",
                         filters: [Self.stateFilter]) { url in
            self.saveState(to: url)
        }
    }

    func saveState(to url: URL, message: String = "State saved") {
        host?.send { s in
            let data = s.machine.snapshot(createdBy: "LinuxArch")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(data).write(to: url)
                Task { @MainActor in self.show(message) }
            } catch {
                Task { @MainActor in self.alert("Could not save the state", error.localizedDescription) }
            }
        }
    }

    func loadState() {
        FileDialogs.open(parent: parent, title: "Load State", filters: [Self.stateFilter]) { url in
            self.loadState(url)
        }
    }

    func loadState(_ url: URL, message: String? = nil) {
        Task { @MainActor in
            guard await confirmDiscChanges(before: "loading a state") else { return }
            guard let host, let data = FileManager.default.contents(atPath: url.path) else {
                alert("Could not read \(url.lastPathComponent)", "")
                return
            }
            stopRecordingIfNeeded()
            host.send { s in
                do {
                    // Reuse open hard disc images when the state names the same files.
                    let header = try Snapshot.header(of: [UInt8](data))
                    let current = s.machine.hdc?.drives ?? []
                    let reuse: [HardDiscImage?]? = header.configuration.hardDiscs.isEmpty ? nil : header.configuration.hardDiscs.enumerated().map { i, p in
                        i < current.count && current[i]?.path == p ? current[i] : (p.flatMap { try? HardDiscImage.open(path: $0) })
                    }
                    let m = try Machine.restore(snapshot: [UInt8](data), rom: s.machine.rom, hardDiscs: reuse)
                    s.replace(with: m)
                    s.host.setPersistCMOS(false, session: s)
                    let name = m.fdc.drives[0].disc?.sourcePath.map { ($0 as NSString).lastPathComponent }
                    let config = m.configuration
                    Task { @MainActor in
                        // The state brings its own machine: show what it is.
                        self.model = config.model; self.cpu = config.cpu; self.ramKB = config.ramKB
                        self.hardDiscs = (0..<config.model.hardDiscSlots).map { $0 < config.hardDiscs.count ? config.hardDiscs[$0] : nil }
                        self.discName = name
                        self.discIsUntitled = false
                        noteRecentFile(url)
                        if let message { self.show(message) }
                    }
                } catch {
                    Task { @MainActor in self.alert("Could not load \(url.lastPathComponent)", "\(error)") }
                }
            }
        }
    }

    func quickSave() { saveState(to: Self.quickStateURL, message: "Quick saved") }

    func quickLoad() {
        guard FileManager.default.fileExists(atPath: Self.quickStateURL.path) else {
            alert("No quick save yet", "Use Quick Save first.")
            return
        }
        loadState(Self.quickStateURL, message: "Quick loaded")
    }

    // MARK: Rewind

    var showingTimeline = false

    /// Goes back `seconds` of guest time, as far as the history goes.
    func rewind(seconds: Double) {
        guard let host else { return }
        let back = UInt64(seconds * Double(MasterClock.ticksPerSecond))
        let now = host.sendAndWait { $0.machine.nominalTicks }
        seek(to: now > back ? now - back : 0)
    }

    func seek(to ticks: UInt64) {
        guard let host else { return }
        Task { @MainActor in
            let changed = host.sendAndWait { $0.rewinder.hardDiscChanged(goingBackTo: ticks, from: $0.machine) }
            if changed {
                guard await Alerts.confirm("Rewind past hard disc changes?",
                                           "The hard disc has been written since then. Rewinding does not undo those writes, so RISC OS may find its files changed underneath it and could damage the disc.",
                                           button: "Rewind", destructive: true, parent: parent) else { return }
            }
            stopRecordingIfNeeded()
            host.send { Self.seek($0, to: ticks) }
        }
    }

    nonisolated private static func seek(_ s: EmulatorHost.Session, to ticks: UInt64) {
        guard let earliest = s.rewinder.earliestTicks else { return }
        if let m = try? s.rewinder.machine(at: max(earliest, ticks), from: s.machine) {
            s.replace(with: m, keepHistory: true)
        }
    }

    /// The history's points (guest ticks) and the current time.
    func rewindPoints() async -> (points: [UInt64], now: UInt64) {
        await perform { s in (s.rewinder.points.map(\.ticks), s.machine.nominalTicks) } ?? ([], 0)
    }

    /// A history point's thumbnail (0xAARRGGBB, `Rewinder.thumbnailWidth`
    /// by `Rewinder.thumbnailHeight`), or nil.
    func rewindThumbnail(_ index: Int) async -> [UInt32]? {
        let pixels = await perform { s -> [UInt32] in
            s.rewinder.points.indices.contains(index) ? s.rewinder.points[index].thumbnail : []
        } ?? []
        return pixels.count == Rewinder.thumbnailWidth * Rewinder.thumbnailHeight ? pixels : nil
    }

    /// Runs `body` on the emulation thread and returns its result.
    private func perform<T: Sendable>(_ body: @escaping @Sendable (EmulatorHost.Session) -> T) async -> T? {
        guard let host else { return nil }
        return await withCheckedContinuation { c in host.send { c.resume(returning: body($0)) } }
    }

    // MARK: Zoom

    static let zoomLevels: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    @ObservationIgnored private var currentZoom = 1.0
    /// The zoom level the window is at, if it is at one (to within 1%).
    private(set) var zoom: Double? = 1

    func pictureZoomed(_ z: Double) {
        currentZoom = z
        let level = Self.zoomLevels.first { abs($0 - z) < 0.01 * $0 }
        if level != zoom { zoom = level }
    }

    func setZoom(_ z: Double) {
        window?.applyZoom(z)
    }

    /// View ▸ Make 16:9.
    func makeWidescreen() {
        window?.makeWidescreen()
    }

    func zoom(in zoomIn: Bool) {
        let next = zoomIn ? Self.zoomLevels.first { $0 > currentZoom * 1.01 } : Self.zoomLevels.last { $0 < currentZoom * 0.99 }
        if let next { setZoom(next) }
    }

    // MARK: Agents

    /// The screen address under the mouse, while the debugger is open.
    func hover(x: Int, y: Int) {
        guard inspecting, let host else { inspection = nil; return }
        inspection = host.sendAndWait { s in s.machine.screenAddress(x: x, y: y) }
    }

    /// An agent switched the hardware: show it as this window's.
    func adoptAgentHardware(_ c: MachineConfiguration) {
        model = c.model; cpu = c.cpu; ramKB = c.ramKB; monitor = c.monitorType
        hardDiscs = (0..<c.model.hardDiscSlots).map { $0 < c.hardDiscs.count ? c.hardDiscs[$0] : nil }
        if let p = c.romPaths.first { romPath = p }
    }

    // MARK: Window

    /// The model, with an upgrade processor when one is fitted.
    var machineName: String { model.displayName + (cpu != model.defaultCPU ? " + \(cpu.rawValue)" : "") }

    /// The window's title and the notes under it.
    var title: (title: String, notes: [String]) {
        if host == nil { return ("LinuxArch", []) }
        let name = owner.map { "\($0.stationTitle(self)) — \(machineName)" } ?? session.map { "\($0.title) — \(machineName)" } ?? machineName
        let t = discName.map { "\(name) — \($0)" + (disc.modified ? " (edited)" : "") } ?? name
        var notes: [String] = []
        if paused { notes.append("Paused") } else if heldForAgent { notes.append("Held by AI Agent") }
        if !speedLimited { notes.append("Full Speed") }
        if recordingURL != nil { notes.append("● Recording") }
        return (t, notes)
    }

    /// Quit check: every window's disc changes.
    static func confirmQuit() async -> Bool {
        for machine in live where !(await machine.confirmDiscChanges(before: "quitting")) { return false }
        live.forEach { $0.syncHardDiscs() }
        return true
    }

    func alert(_ message: String, _ info: String) {
        Alerts.show(message, info.isEmpty ? nil : info, parent: parent)
    }

    /// Shows a toast over the picture.
    func show(_ message: String) {
        toast = message
    }
}
