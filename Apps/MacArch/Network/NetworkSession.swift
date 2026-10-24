import AppKit
import ArchimedesCore
import Observation

/// An open network: its project, saved as it changes, and its machines,
/// running. Each machine that's on has a `MachineController`, whether or
/// not it has a window, so its window, tile and canvas card all show the
/// same running machine. (After MacBeeb's NetworkSession.)
@MainActor
@Observable
final class NetworkSession: StationOwner {
    private(set) var project: NetworkProject
    /// Where it's saved: a `.macarchnet` package. Changes are saved there as
    /// they're made.
    private(set) var url: URL
    @ObservationIgnored let network: NetworkHost
    /// The machines switched on, by node.
    private(set) var controllers: [UUID: MachineController] = [:]
    /// The nodes selected on the canvas.
    var selection: Set<UUID> = []
    /// The station typed into (in the tiles) and heard.
    private(set) var focused: UUID?
    /// The whole network is paused.
    private(set) var paused = false
    /// The network's status, refreshed a few times a second.
    private(set) var status = NetworkHost.Status()
    /// The nodes that put something on the line since the last refresh.
    private(set) var transmitting: Set<UUID> = []
    /// A save failed: why.
    private(set) var saveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored let thumbnails = ThumbnailCache()

    /// The sessions open, by package.
    private(set) static var open: [URL: NetworkSession] = [:]

    /// How a package's URL is kept: symlinks resolved (/tmp and /private/tmp
    /// are one place) and standardised.
    static func key(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    /// The open session for the network at `url`, if it's open.
    static func opened(_ url: URL) -> NetworkSession? { open[key(url)] }

    /// The session for the network at `url`, opening it if it isn't.
    static func session(for url: URL) throws -> NetworkSession {
        let key = key(url)
        if let session = open[key] { return session }
        let session = try NetworkSession(url: key)
        open[key] = session
        AppAgentContext.startServer()
        return session
    }

    private init(url: URL) throws {
        self.url = url
        let loaded = try NetworkPackage.load(from: url)
        project = loaded
        network = NetworkHost(clockRate: loaded.clockRate)
        network.start()
        for node in Self.serversFirst(project.nodes) where node.isMachine && node.poweredOn {
            powerOn(node.id, remember: false)
        }
        focus(project.workspace.tiles.first { controllers[$0] != nil } ?? project.stations.first { controllers[$0.id] != nil }?.id)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentNetworks.shared.add(url)
    }

    private func refreshStatus() {
        let status = network.status
        guard status != self.status else {
            if !transmitting.isEmpty { transmitting = [] }
            return
        }
        let before = self.status.traffic
        let sent = Set(status.traffic.compactMap { station, traffic in traffic.bytes != before[station]?.bytes ? station : nil })
        let nodes = Set(project.nodes.filter { $0.stationNumber.map { sent.contains(UInt8(clamping: $0)) } ?? false }.map(\.id))
        if nodes != transmitting { transmitting = nodes }
        self.status = status
        startWaitingMachines()
    }

    /// Closes the network: its machines stop, and it's saved.
    func close() {
        saveNow()
        statusTimer?.invalidate()
        for controller in controllers.values { controller.detachFromNetwork() }
        network.stop()
        controllers.removeAll()
        Self.open[url] = nil
    }

    // MARK: Saving

    /// Changes the project and saves it shortly (changes in quick
    /// succession, like a drag, save once).
    func update(_ change: (inout NetworkProject) -> Void) {
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        if project.clockRate != self.project.clockRate { network.setClock(project.clockRate) }
        self.project = project
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try NetworkPackage.save(project, to: url)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Saves a copy elsewhere and carries on with the copy. Machines that
    /// are on are switched off and on again, to use the copy's discs.
    func saveAs(_ newURL: URL) throws {
        saveNow()
        let key = Self.key(newURL)
        let on = Array(controllers.keys)
        for id in on { powerOff(id, remember: false) }
        if FileManager.default.fileExists(atPath: key.path) { try FileManager.default.removeItem(at: key) }
        try FileManager.default.copyItem(at: url, to: key)
        Self.open[url] = nil
        url = key
        Self.open[key] = self
        update { $0.name = key.deletingPathExtension().lastPathComponent }
        saveNow()
        for id in on { powerOn(id, remember: false) }
        RecentNetworks.shared.add(key)
    }

    // MARK: Nodes

    func node(_ id: UUID) -> NetworkNode? { project[id] }

    /// Adds a machine (or the clock) at a canvas point, switched on.
    @discardableResult
    func add(_ kind: NetworkNode.Kind, model: MachineModel = .a3000, at point: CanvasPoint) -> UUID? {
        var node: NetworkNode
        if kind == .clock {
            guard !project.hasClock else { return nil }
            node = .clock(at: point)
        } else {
            let preferred = kind.conventionalStation.flatMap { project.stationNumberProblem($0, for: UUID()) == nil ? $0 : nil }
            guard let number = preferred ?? project.freeStationNumber() else { return nil }
            if kind == .fileServer {
                node = .fileServer(at: point, number: number)
                node.name = project.freeName("File Server")
            } else {
                node = NetworkNode(kind: .station, name: project.freeName("\(model.rawValue) \(number)"), stationNumber: number,
                                   setup: StationSetup(model: model), position: point)
            }
        }
        update { $0.nodes.append(node) }
        if node.isMachine { powerOn(node.id) }
        return node.id
    }

    /// A copy of a machine beside it, with the next free station number and
    /// copies of its discs.
    func duplicate(_ id: UUID) {
        guard var node = project[id], node.isMachine, let number = project.freeStationNumber(from: (node.stationNumber ?? 0) + 1) else { return }
        let original = node.id
        node.id = UUID()
        node.stationNumber = number
        node.name = project.freeName(node.name)
        node.position.x += 40
        node.position.y += 40
        node.discs = node.discs.compactMapValues { try? NetworkPackage.importMedia(NetworkPackage.url(of: $0, in: url), into: url) }
        node.hardDiscs = node.hardDiscs.compactMapValues { try? NetworkPackage.importMedia(NetworkPackage.url(of: $0, in: url), into: url) }
        try? FileManager.default.copyItem(at: NetworkPackage.cmosURL(of: original, in: url), to: NetworkPackage.cmosURL(of: node.id, in: url))
        update { $0.nodes.append(node) }
        if node.poweredOn { powerOn(node.id) }
    }

    /// Takes nodes off the network: their machines stop, and their discs'
    /// copies go.
    func remove(_ ids: Set<UUID>) {
        for id in ids { powerOff(id, remember: false) }
        update { project in
            project.nodes.removeAll { ids.contains($0.id) }
            project.workspace.tiles.removeAll { ids.contains($0) }
        }
        selection.subtract(ids)
        removeUnusedMedia()
        saveNow()
    }

    func move(_ id: UUID, to point: CanvasPoint) {
        update { $0[id]?.position = point }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update { $0[id]?.name = trimmed }
    }

    /// Changes a station's number, unless another machine has it or it's
    /// reserved. Returns why not, if not. A machine that's on restarts:
    /// RISC OS reads its number from CMOS when it starts.
    @discardableResult
    func setStationNumber(_ id: UUID, to number: Int) -> String? {
        if let problem = project.stationNumberProblem(number, for: id) { return problem }
        guard project[id]?.stationNumber != number else { return nil }
        update { $0[id]?.stationNumber = number }
        if isOn(id) {
            powerOff(id, remember: false)
            powerOn(id, remember: false)
        }
        return nil
    }

    /// Changes what a machine starts up with (it's kept in CMOS): a
    /// machine that's on restarts.
    func setStartup(_ id: UUID, _ startup: NetworkStartup?) {
        guard project[id]?.startup != startup else { return }
        update { $0[id]?.startup = startup }
        if isOn(id) {
            powerOff(id, remember: false)
            powerOn(id, remember: false)
        }
    }

    /// Changes a machine's hardware: a machine that's on is power cycled.
    func setSetup(_ id: UUID, _ setup: StationSetup) {
        if let controller = controllers[id] {
            controller.setHardware(model: setup.model, cpu: setup.cpu, ramKB: setup.ramKB, monitor: setup.monitor,
                                   romPath: romPath(for: setup))
        } else {
            update { $0[id]?.setup = setup }
        }
    }

    // MARK: Power

    func isOn(_ id: UUID) -> Bool { controllers[id] != nil }

    /// Switches a machine on: a fresh machine, as at power on.
    func powerOn(_ id: UUID, remember: Bool = true) {
        guard controllers[id] == nil, let node = project[id], node.isMachine, let setup = node.setup else { return }
        if waitsForServer(node) {
            waitingForServer.insert(id)
            if remember { update { $0[id]?.poweredOn = true } }
            return
        }
        waitingForServer.remove(id)
        if node.kind == .fileServer && node.runsLevel4 == true { serverStarted[id] = network.status.ticks }
        do {
            let (machine, cmos, rom, discs) = try makeMachine(node, setup)
            let controller = MachineController(station: id, machine: machine, cmosPath: cmos, romPath: rom,
                                               hardDiscs: discs, owner: self)
            controller.watchesConsole = node.kind == .fileServer
            if let disc = node.discs[0] { controller.noteNetworkDisc(disc.displayName) }
            controllers[id] = controller
            if let host = controller.host { network.addStation(id: id, host: host) }
            if remember { update { $0[id]?.poweredOn = true } }
            if focused == nil { focus(id) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(node.name) can’t start"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    /// The machine a node describes, with the network's copies of its
    /// discs and CMOS: (machine, CMOS path, ROM path, hard disc paths).
    private func makeMachine(_ node: NetworkNode, _ setup: StationSetup) throws -> (Machine, String, String, [String?]) {
        guard let rom = romPath(for: setup) else { throw MachineError.noROM }
        var c = MachineConfiguration(model: setup.model)
        c.cpu = setup.model.cpuChoices.contains(setup.cpu) ? setup.cpu : setup.model.defaultCPU
        c.ramKB = setup.model.ramChoices.contains(setup.ramKB) ? setup.ramKB : setup.model.defaultRAMKB
        c.monitorType = setup.model.monitorChoices.contains(setup.monitor) ? setup.monitor : .standard
        c.romPaths = [rom]
        c.hardDiscs = (0..<setup.model.hardDiscSlots).map { node.hardDiscs[$0].map { NetworkPackage.url(of: $0, in: url).path } }
        c.econetStation = node.stationNumber
        c.cmosSettings = cmosSettings(for: node, ramKB: c.ramKB)
        let cmos = NetworkPackage.cmosURL(of: node.id, in: url).path
        // First boot, or a CMOS RISC OS never set up: Delete held resets it.
        if let d = FileManager.default.contents(atPath: cmos), !Machine.cmosNeverConfigured([UInt8](d)) {
            c.cmosPath = cmos
        } else {
            c.powerOnKeys = [0x34]
        }
        let machine = try Machine(configuration: c)
        if let disc = node.discs[0], let image = try? FloppyImage.open(path: NetworkPackage.url(of: disc, in: url).path) {
            machine.insertFloppy(image)
        }
        return (machine, cmos, rom, c.hardDiscs)
    }

    /// The ROM for a machine: the version it asks for from the ROMs the
    /// user has added (RISC OS 3 where 2 can't drive the hardware), else
    /// the one chosen in Settings.
    func romPath(for setup: StationSetup) -> String? { Self.romPath(for: setup) }

    static func romPath(for setup: StationSetup) -> String? {
        let library = AppSettings.shared.romLibrary
        let usable = library.filter { !(setup.model.hasNewIO && $0.version.hasPrefix("RISC OS 2")) }
        if let wanted = setup.rom, let entry = usable.first(where: { $0.version.hasPrefix(wanted) }) { return entry.path }
        if let path = AppSettings.shared.romPath, usable.contains(where: { $0.path == path }) || library.isEmpty { return path }
        return usable.first?.path ?? AppSettings.shared.romPath
    }

    /// Switches a machine off: it stops, and what's in its memory is gone.
    func powerOff(_ id: UUID, remember: Bool = true) {
        if waitingForServer.remove(id) != nil, remember { update { $0[id]?.poweredOn = false } }
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.detachFromNetwork()
        network.removeStation(id: id)
        thumbnails.forget(id)
        if focused == id { focused = nil }
        if remember { update { $0[id]?.poweredOn = false } }
    }

    func togglePower(_ id: UUID) { isOn(id) || waitingForServer.contains(id) ? powerOff(id) : powerOn(id) }

    // MARK: Network boot

    /// Machines that boot from the network, held off until the file
    /// server's had time to start: it takes about 30 s, and a machine that
    /// boots before it's ready finds nobody to log on to. (A classroom's
    /// server was on first.)
    private(set) var waitingForServer: Set<UUID> = []
    /// When each Level 4 server was switched on, in network ticks.
    @ObservationIgnored private var serverStarted: [UUID: UInt64] = [:]
    /// From power-on to Level 4's "Ready", with some to spare.
    static let serverStartTicks = 35 * EconetTime.ticksPerSecond

    /// File servers, then the rest, in order.
    static func serversFirst(_ nodes: [NetworkNode]) -> [NetworkNode] {
        nodes.filter { $0.kind == .fileServer } + nodes.filter { $0.kind != .fileServer }
    }

    /// Whether a machine that boots from the network has to wait: a Level
    /// 4 server on this network is on, but hasn't been for long.
    private func waitsForServer(_ node: NetworkNode) -> Bool {
        guard node.startup == .networkBoot || node.waitsForServer == true else { return false }
        let now = network.status.ticks
        return project.nodes.contains { server in
            server.kind == .fileServer && server.runsLevel4 == true && isOn(server.id)
                && serverStarted[server.id].map { now < $0 + Self.serverStartTicks } ?? false
        }
    }

    /// Those that were waiting and needn't now.
    private func startWaitingMachines() {
        for id in waitingForServer {
            guard let node = project[id] else { waitingForServer.remove(id); continue }
            if !waitsForServer(node) { powerOn(id, remember: false) }
        }
    }

    /// Off and on again.
    func coldBoot(_ id: UUID) {
        guard let controller = controllers[id] else { powerOn(id); return }
        controller.powerCycle()
    }

    /// The reset button.
    func reset(_ id: UUID) { controllers[id]?.reset() }

    /// A suspended station stops where it is while the others run on.
    func isSuspended(_ id: UUID) -> Bool { controllers[id]?.paused ?? false }

    func setSuspended(_ id: UUID, _ suspended: Bool) { controllers[id]?.setPaused(suspended) }

    func powerOnAll() {
        for node in Self.serversFirst(project.nodes) where node.isMachine { powerOn(node.id) }
    }

    func powerOffAll() {
        for id in Array(controllers.keys) { powerOff(id) }
    }

    func resetAll() {
        for controller in controllers.values { controller.reset() }
    }

    /// Pauses the whole network: no time passes anywhere, so nothing on it
    /// times out.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        network.setPaused(paused)
    }

    // MARK: Discs

    /// Asks for a floppy image and puts it in a machine's drive: into the
    /// running machine if it's on, else for when it's switched on.
    func chooseDisc(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        if let controller = controllers[id] {
            controller.insertDisc(source)
            return
        }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[0] = media }
            removeUnusedMedia()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func eject(_ id: UUID) {
        if let controller = controllers[id] {
            controller.ejectDisc()
        } else {
            update { $0[id]?.discs[0] = nil }
            removeUnusedMedia()
        }
    }

    // MARK: Level 4 File Server

    /// What a machine keeps in CMOS: a Level 4 server boots from its hard
    /// disc with the memory the server needs.
    func cmosSettings(for node: NetworkNode, ramKB: Int) -> [CMOSSetting] {
        if node.kind == .fileServer && node.runsLevel4 == true { return Level4.cmosSettings(ramKB: ramKB) }
        return node.startup?.cmosSettings ?? []
    }

    /// Sets a file server up with Acorn's Level 4 File Server, which
    /// MacArch includes: a new hard disc with the server on it, which
    /// starts when the machine does.
    func setUpLevel4(_ id: UUID) {
        do {
            try setUpLevel4(id, disc: nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    enum Level4Problem: LocalizedError {
        case needsRISCOS3, noHardDisc(MachineModel), missing
        var errorDescription: String? {
            switch self {
            case .needsRISCOS3: "Level 4 File Server needs RISC OS 3.10 or later. Add a RISC OS 3 ROM in Settings ▸ ROMs."
            case .noHardDisc(let model): "The \(model.rawValue) has no hard disc interface. Choose another model for the server."
            case .missing: "MacArch's copy of the Level 4 File Server is missing from the app."
            }
        }
    }

    /// The Level 4 File Server disc MacArch includes (Release 3's "Level 4"
    /// disc), or, run from the source tree, the one beside the sources.
    static var includedLevel4Disc: [UInt8]? {
        let url = Bundle.main.url(forResource: "Level4", withExtension: "adf")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Level4.adf")
        return FileManager.default.contents(atPath: url.path).map { [UInt8]($0) }
    }

    /// Sets up the server, from the Level 4 disc image at `disc` (nil: the
    /// one MacArch includes). A server that's on restarts, and so do the
    /// machines that boot from it.
    func setUpLevel4(_ id: UUID, disc: URL?) throws {
        let bytes: [UInt8]
        if let disc {
            guard let read = FileManager.default.contents(atPath: disc.path).map({ [UInt8]($0) }) else { throw MediaError.unreadable(disc.path) }
            bytes = read
        } else {
            guard let included = Self.includedLevel4Disc else { throw Level4Problem.missing }
            bytes = included
        }
        let wasOn = isOn(id)
        var project = self.project
        try Self.installLevel4(id, in: &project, package: url, disc: bytes)
        if wasOn { powerOff(id, remember: false) }
        update { $0 = project }
        removeUnusedMedia()
        if wasOn { powerOn(id) }
        // Machines that boot from the network start again, and wait for it.
        for node in project.nodes where node.startup == .networkBoot && isOn(node.id) {
            powerOff(node.id, remember: false)
            powerOn(node.id, remember: false)
        }
    }

    /// Makes the server's hard disc in the package and sets the node up to
    /// run it (RISC OS 3, Level 4's configuration). For a demo's network,
    /// the disc has the demo's programs too.
    static func installLevel4(_ id: UUID, in project: inout NetworkProject, package url: URL, disc bytes: [UInt8]) throws {
        guard var node = project[id], var setup = node.setup else { return }
        guard Level4.isLevel4Disc(bytes) else { throw Level4.SetupError.notLevel4 }
        guard setup.model.hardDiscSlots > 0 else { throw Level4Problem.noHardDisc(setup.model) }
        // A server runs RISC OS 3 where it can (Release 3 must).
        let riscOS3 = AppSettings.shared.romLibrary.filter { !$0.version.hasPrefix("RISC OS 2") }
        let current = romPath(for: setup).flatMap { path in AppSettings.shared.romLibrary.first { $0.path == path } }
        if current?.version.hasPrefix("RISC OS 2") ?? true {
            if let rom = riscOS3.first { setup.rom = rom.version } else if Level4.requiresRISCOS3(bytes) { throw Level4Problem.needsRISCOS3 }
        }
        let folder = NetworkPackage.mediaURL(in: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8) + "-FileServer.hdf"
        let geometry = setup.model.hasIDE ? HardDiscGeometry.idePresets[0].geometry : HardDiscGeometry(cylinders: 615, heads: 4)
        let path = folder.appendingPathComponent(String(name)).path
        switch project.demo {
        case .distributedMandelbrot:
            // With the demo's programs, and its workers' boot file.
            try MandelbrotNetwork.createFileServerDisc(path: path, geometry: geometry, fromLevel4Disc: bytes)
        case nil:
            try Level4.createServerDisc(path: path, geometry: geometry, fromDisc: bytes)
        }
        node.setup = setup
        node.kind = .fileServer
        node.runsLevel4 = true
        node.hardDiscs[0] = MediaReference(storedName: String(name), displayName: "File Server (Level 4)", originalPath: nil)
        project[id] = node
    }

    private func removeUnusedMedia() {
        for old in NetworkPackage.unusedMedia(of: project, in: url) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Focus

    /// The station typed into in the tiles, and heard.
    func focus(_ id: UUID?) {
        guard focused != id || id == nil else { return }
        if let old = focused { controllers[old]?.setAudible(false) }
        focused = id.flatMap { controllers[$0] != nil ? $0 : nil }
        if let focused { controllers[focused]?.setAudible(true) }
    }

    /// The next (or previous) machine that's on, by station number.
    func focusNext(_ forward: Bool = true) {
        let on = project.stations.filter { controllers[$0.id] != nil }.map(\.id)
        guard !on.isEmpty else { return }
        let index = focused.flatMap { on.firstIndex(of: $0) } ?? (forward ? on.count - 1 : 0)
        focus(on[(index + (forward ? 1 : on.count - 1)) % on.count])
    }

    // MARK: StationOwner

    func stationSetupChanged(_ controller: MachineController) {
        guard let id = controller.stationID, var setup = project[id]?.setup else { return }
        setup.model = controller.model
        setup.cpu = controller.cpu
        setup.ramKB = controller.ramKB
        setup.monitor = controller.monitor
        if let path = controller.romPath, let entry = AppSettings.shared.romLibrary.first(where: { $0.path == path }) {
            setup.rom = entry.version
        }
        update { $0[id]?.setup = setup }
    }

    func station(_ controller: MachineController, willInsert source: URL, drive: Int) -> URL? {
        guard let id = controller.stationID else { return nil }
        // Already one of the package's copies.
        if source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(NetworkPackage.mediaURL(in: url).resolvingSymlinksInPath().standardizedFileURL.path) { return source }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[drive] = media }
            removeUnusedMedia()
            return NetworkPackage.url(of: media, in: url)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func station(_ controller: MachineController, willFitHardDiscs paths: [String?]) -> [String?] {
        guard let id = controller.stationID else { return paths }
        let media = NetworkPackage.mediaURL(in: url).resolvingSymlinksInPath().standardizedFileURL.path
        var fitted: [String?] = []
        var references: [Int: MediaReference] = [:]
        for (drive, path) in paths.enumerated() {
            guard let path else { fitted.append(nil); continue }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            if source.path.hasPrefix(media) {
                // Already the network's: keep its reference.
                references[drive] = project[id]?.hardDiscs.values.first { NetworkPackage.url(of: $0, in: url).resolvingSymlinksInPath().standardizedFileURL == source }
                    ?? MediaReference(storedName: source.lastPathComponent, displayName: source.lastPathComponent)
                fitted.append(source.path)
            } else if let copy = try? NetworkPackage.importMedia(source, into: url) {
                references[drive] = copy
                fitted.append(NetworkPackage.url(of: copy, in: url).path)
            } else {
                fitted.append(nil)
            }
        }
        update { $0[id]?.hardDiscs = references }
        removeUnusedMedia()
        return fitted
    }

    func station(_ controller: MachineController, didEject drive: Int) {
        guard let id = controller.stationID else { return }
        update { $0[id]?.discs[drive] = nil }
        removeUnusedMedia()
    }

    func stationNumber(_ controller: MachineController) -> Int? {
        controller.stationID.flatMap { project[$0]?.stationNumber }
    }

    func stationCMOSPath(_ controller: MachineController) -> String? {
        controller.stationID.map { NetworkPackage.cmosURL(of: $0, in: url).path }
    }

    func stationCMOSSettings(_ controller: MachineController) -> [CMOSSetting] {
        guard let id = controller.stationID, let node = project[id] else { return [] }
        return cmosSettings(for: node, ramKB: controller.ramKB)
    }

    func stationTitle(_ controller: MachineController) -> String {
        guard let id = controller.stationID, let node = project[id] else { return "Station" }
        return node.stationNumber.map { "\(node.name) · station \($0)" } ?? node.name
    }
}
