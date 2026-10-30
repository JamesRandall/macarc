import AppKit
import ArchimedesCore

/// `MACARCH_SELFTEST_MYMACHINES=1`: saves the running machine to My Machines,
/// captures the gallery (-mymachines.png), starts the saved machine from it
/// and captures that window (-mymachine.png), then reports (.mymachines.txt).
@MainActor
enum MyMachinesSelfTest {
    static let openRequest = Notification.Name("MacArchOpenMyMachines")

    static func run(_ machine: MachineController, path: String) async {
        var report: [String] = []
        func capture(_ window: NSWindow, _ suffix: String) {
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: suffix + ".png")))
        }
        do {
            let id = try await MyMachines.shared.save(machine, name: "Self-test \(machine.model.rawValue)")
            guard let entry = MyMachines.shared.entry(id) else { throw MachineError.badConfiguration("saved entry missing") }
            let files = ["info.json", "machine.json", "machine.cmos", "screen.png"].filter {
                FileManager.default.fileExists(atPath: entry.folder.appendingPathComponent($0).path)
            }
            report.append("saved: \(entry.name) files=\(files) problem=\(entry.problem ?? "none") savedID=\(machine.savedMachineID == id)")
            NotificationCenter.default.post(name: openRequest, object: nil)
            try await Task.sleep(for: .seconds(2))
            if let window = NSApp.windows.first(where: { $0.title == MyMachinesView.title && $0.isVisible }) {
                window.setFrame(NSRect(x: 60, y: 60, width: 980, height: 700), display: true)
                try await Task.sleep(for: .seconds(1))
                capture(window, "-mymachines")
                report.append("gallery shown")
            } else {
                report.append("gallery NOT shown")
            }
            do {
                let started = try MyMachines.shared.prepare(id)
                NotificationCenter.default.post(name: openRequest, object: started.id)
            } catch {
                report.append("start failed: \(error)")
            }
            try await Task.sleep(for: .seconds(4))
            let started = MachineController.live.allObjects.filter { $0.startedFromMyMachines && $0.savedMachineID == id }
            if let s = started.first {
                report.append("started: model=\(s.model.rawValue) cpu=\(s.cpu.rawValue) ram=\(s.ramKB) rom=\(s.romVersion) running=\(s.host != nil) error=\(s.startError ?? "none")")
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(MachineConfigurationCommands.windowID) == true }) {
                    capture(window, "-mymachine")
                }
                report.append("running(id) finds it: \(MyMachines.shared.running(id) === s || MyMachines.shared.running(id)?.startedFromMyMachines == false)")
            } else {
                report.append("NOT started")
            }
            // Created by hand: an A5000, never started.
            let settings = AppSettings.shared
            guard let rom = settings.preferredROM(for: .a5000) else { throw MachineError.badConfiguration("no ROM for an A5000") }
            // With a new hard disc, made as Create Machine's New… makes one.
            let disc = (AppSettings.supportDirectory as NSString).appendingPathComponent("Created A5000 drive 4.hdf")
            try? FileManager.default.removeItem(atPath: disc)
            try ADFSFormatter.createFormattedImage(path: disc, geometry: HardDiscGeometry.idePresets[0].geometry, name: "Created")
            let made = try MyMachines.shared.create(name: "Created A5000", model: .a5000, cpu: .arm3, ramKB: 4096, monitor: .vga,
                                                     romPath: rom, hardDiscs: [disc, nil])
            let before = MyMachines.shared.entry(made)?.configuration
            report.append("created: rom=\(settings.romLibrary.first { $0.path == rom }.map(settings.label) ?? rom) keys=\(before?.powerOnKeys ?? []) cmos=\(before?.cmosPath ?? "none")")
            let second = try MyMachines.shared.prepare(made)
            NotificationCenter.default.post(name: openRequest, object: second.id)
            try await Task.sleep(for: .seconds(3))
            let after = MyMachines.shared.entry(made)?.configuration
            report.append("created started: model=\(second.model.rawValue) cpu=\(second.cpu.rawValue) ram=\(second.ramKB) monitor=\(second.monitor.rawValue) rom=\(second.romVersion) running=\(second.host != nil) error=\(second.startError ?? "none")")
            report.append("after first start: keys=\(after?.powerOnKeys ?? [99]) cmos=\(after?.cmosPath ?? "none") hardDiscs=\(second.hardDiscs.map { $0.map { ($0 as NSString).lastPathComponent } ?? "-" })")
            NotificationCenter.default.post(name: openRequest, object: nil)
            try await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.title == MyMachinesView.title && $0.isVisible }) {
                capture(window, "-mymachines2")
            }
        } catch {
            report.append("error: \(error)")
        }
        try? (report.joined(separator: "\n") + "\n").write(toFile: path + ".mymachines.txt", atomically: true, encoding: .utf8)
    }
}
