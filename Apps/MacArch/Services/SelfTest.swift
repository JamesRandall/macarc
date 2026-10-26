import AppKit
import ArchimedesCore

/// `MACARCH_SELFTEST=/path/out.png MacArch`: boots, then writes the menu bar
/// structure (out.png.menus.txt), the window with its toolbar
/// (out-window.png) and the display as drawn (out-display.png), and quits.
/// For checking the app end to end without looking at it.
@MainActor
enum SelfTest {
    private static var started = false
    static func runIfRequested(_ machine: MachineController) {
        guard !started, let path = ProcessInfo.processInfo.environment["MACARCH_SELFTEST"] else { return }
        started = true
        if let part = ProcessInfo.processInfo.environment["MACARCH_SELFTEST_INTERNET"] {
            InternetSelfTest.run(path, host: part == "host")
            return
        }
        // MACARCH_SELFTEST_WELCOME=1: the welcome screen, captured (-welcome.png).
        if ProcessInfo.processInfo.environment["MACARCH_SELFTEST_WELCOME"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                NotificationCenter.default.post(name: WelcomeScreen.openRequest, object: nil)
                if ProcessInfo.processInfo.environment["MACARCH_SELFTEST_WELCOME_IMPORT"] != nil { return }
                try? await Task.sleep(for: .seconds(4))
                if let window = NSApp.windows.first(where: { $0.title == WelcomeScreen.title && $0.isVisible }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-welcome.png")))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let folder = ProcessInfo.processInfo.environment["MACARCH_SELFTEST_CLASSICS"] {
            LibrarySelfTest.runClassics(path, folder: folder, machine: machine)
            return
        }
        if let disc = ProcessInfo.processInfo.environment["MACARCH_SELFTEST_LIBRARY"] {
            LibrarySelfTest.run(path, disc: disc, machine: machine)
            return
        }
        let wait = Double(ProcessInfo.processInfo.environment["MACARCH_SELFTEST_SECONDS"] ?? "") ?? 20
        let launched = Date()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            let env = ProcessInfo.processInfo.environment
            if let input = env["MACARCH_SELFTEST_MACHINE_CONFIG"] {
                do {
                    let source = URL(fileURLWithPath: input)
                    let expected = try MachineConfigurationFile.load(from: source)
                    try machine.importConfiguration(from: source, confirmRestart: false)
                    try await Task.sleep(for: .seconds(1))
                    let exported = URL(fileURLWithPath: path + ".machine.json")
                    try await machine.exportConfiguration(to: exported)
                    let actual = try MachineConfigurationFile.load(from: exported)
                    guard actual.model == expected.model, actual.cpu == expected.cpu,
                          actual.ramKB == expected.ramKB, actual.cmosSettings == expected.cmosSettings,
                          actual.powerOnKeys == expected.powerOnKeys else {
                        throw MachineError.badConfiguration("Imported/exported settings differ")
                    }
                    // Re-import the export into the already-running machine.
                    try machine.importConfiguration(from: exported, confirmRestart: false)
                    let prior = machine.host
                    let bad = URL(fileURLWithPath: path + ".invalid.json")
                    try Data("{invalid}".utf8).write(to: bad)
                    var rejected = false
                    do { try machine.importConfiguration(from: bad, confirmRestart: false) }
                    catch { rejected = true }
                    guard rejected, machine.host === prior else { throw MachineError.badConfiguration("Invalid import was accepted or changed the running machine") }
                    try "PASS: import, export, reimport and failed-import preservation\n".write(toFile: path + ".configuration.txt", atomically: true, encoding: .utf8)
                } catch {
                    try? "FAIL: \(error)\n".write(toFile: path + ".configuration.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }
            }
            if let style = env["MACARCH_SELFTEST_STYLE"].flatMap(DisplayStyle.init(rawValue:)) { machine.displayStyle = style }
            // MACARCH_SELFTEST_IMPORT="a|b": add those as ROMs, as a drop on the welcome screen does.
            if let paths = env["MACARCH_SELFTEST_IMPORT"] {
                let added = await ROMLibrary.shared.add(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
                let report = added.map { "\($0.found.rom.versionString) known=\($0.found.known != nil) from \($0.found.origin) -> \($0.path)" }
                    + ROMLibrary.shared.rejected.map { "rejected \($0.name): \($0.reason)" }
                try? report.joined(separator: "\n").write(toFile: path + ".import.txt", atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(for: .seconds(wait))
            if let z = env["MACARCH_SELFTEST_ZOOM"].flatMap(Double.init) {
                machine.setZoom(z)
                try? await Task.sleep(for: .seconds(1))
            }
            // MACARCH_SELFTEST_DEBUGGER=1: break on the IRQ vector, step, capture, continue.
            if env["MACARCH_SELFTEST_DEBUGGER"] != nil {
                let d = machine.debugger
                d.addBreakpoint(.init(id: 0, kind: .execute, start: 0x18))
                try? await Task.sleep(for: .seconds(1.5))
                let stopped = machine.debugStop
                let pcAtStop = d.snapshot.map { String(format: "&%X", $0.pc) } ?? "?"
                d.removeAllBreakpoints()
                for _ in 0..<3 { d.run(.stepInstruction); try? await Task.sleep(for: .seconds(0.3)) }
                d.setProfiling(true)
                try? await Task.sleep(for: .seconds(1))
                var report = "stop=\(stopped ?? "none") pcAtStop=\(pcAtStop) pcAfterStep=\(d.snapshot.map { String(format: "&%X", $0.pc) } ?? "?") stopNow=\(machine.debugStop ?? "none")\n"
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") && $0.isVisible }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-debugger.png")))
                    report += "debugger window open\n"
                }
                d.pauseOrContinue()
                try? await Task.sleep(for: .seconds(1))
                d.refresh()
                try? await Task.sleep(for: .seconds(0.5))
                report += "after continue: stop=\(machine.debugStop ?? "none") profile frames=\(d.snapshot?.profile?.frames ?? -1) routines=\(d.snapshot?.profile?.routines.count ?? 0) hardware sections=\(d.snapshot?.hardware.count ?? 0)\n"
                try? report.write(toFile: path + ".debugger.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_BASIC=1: a BASIC program, as if its .bas file
            // were dropped, stopped at a breakpoint in a PROC, stepped, then
            // stopped at an error: the debugger's BASIC view each time.
            if env["MACARCH_SELFTEST_BASIC"] != nil {
                machine.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); machine.keyUp(0x0C)
                try? await Task.sleep(for: .seconds(0.5))
                machine.type("BASIC\n")
                try? await Task.sleep(for: .seconds(1.5))
                let file = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: ".bas"))
                try? """
                10 total=0:DIM grid%(2,2)
                20 FOR I%=1 TO 3
                30 PROCadd(I%)
                40 NEXT
                50 PRINT total/0
                60 END
                100 DEF PROCadd(N%)
                110 LOCAL T,name$
                120 T=N%*2:name$="Step "+STR$N%
                130 total=total+T:grid%(N%-1,1)=T
                140 ENDPROC
                """.write(to: file, atomically: true, encoding: .utf8)
                let d = machine.debugger
                d.addBasicBreakpoint(BasicBreakpoint(line: 130, condition: "N%=2"))
                d.setBasicErrorStop(.untrapped)
                d.addBasicWatch("total*10")
                d.addBasicWatch("grid%(0,1)")
                d.toggleBasicArray("grid%(")
                try? await Task.sleep(for: .seconds(0.5))
                machine.runBASICProgram(file)
                machine.debuggerRequested = true
                @MainActor func capture(_ suffix: String) {
                    if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") && $0.isVisible }),
                       let frameView = window.contentView?.superview,
                       let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
                    }
                }
                var report = ""
                @MainActor func note(_ what: String) {
                    let b = d.basic
                    report += "\(what): stop=\(machine.debugStop ?? "none") at=\(b?.stop.map { "\($0)" } ?? "-") frames=\(b?.frames.map { $0.name ?? "main" } ?? []) "
                        + "locals=\(b?.variables.filter(\.isLocal).map(\.name) ?? []) watches=\(b?.watches.map { (try? $0.result.get()).map { "\($0)" } ?? "error" } ?? []) "
                        + "error=\(b?.error.map { "\($0.number) \($0.message)" } ?? "-")\n"
                }
                try? await Task.sleep(for: .seconds(4))
                note("breakpoint")
                capture("basic")
                d.basicStep(.into)
                try? await Task.sleep(for: .seconds(1))
                d.refresh()
                try? await Task.sleep(for: .seconds(0.5))
                note("step")
                capture("basic-step")
                d.removeAllBasicBreakpoints()
                d.basicPauseOrContinue()
                try? await Task.sleep(for: .seconds(3))
                d.refresh()
                try? await Task.sleep(for: .seconds(0.5))
                note("error")
                capture("basic-error")
                try? report.write(toFile: path + ".basic.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_MACLAYOUT=1: Mac-layout typing through the view.
            if env["MACARCH_SELFTEST_MACLAYOUT"] != nil,
               let window = NSApp.windows.first(where: { $0.isVisible }),
               let view = window.contentView?.firstSubview(of: EmulatorNSView.self) {
                let settings = KeyboardSettings.shared
                let saved = settings.mode
                settings.mode = .macLayout
                machine.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); machine.keyUp(0x0C)
                try? await Task.sleep(for: .seconds(0.5))
                @MainActor func shift(_ down: Bool) async {
                    if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                isARepeat: false, keyCode: 56) { view.flagsChanged(with: e) }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                @MainActor func key(_ code: UInt16, _ ch: String, shifted: Bool) async {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shifted ? .shift : [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                    isARepeat: false, keyCode: code) {
                            if type == .keyDown { view.keyDown(with: e) } else { view.keyUp(with: e) }
                        }
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
                await shift(true); await key(19, "@", shifted: true); await shift(false)   // Shift kept
                await shift(true); await key(29, "=", shifted: true); await shift(false)   // Shift lifted
                await key(20, "#", shifted: false)                                         // Shift added
                try? await Task.sleep(for: .seconds(1))
                settings.mode = saved
                let echo = machine.host?.sendAndWait { String($0.machine.recentText.suffix(20)) } ?? ""
                try? "echo=\(echo.debugDescription)\n".write(toFile: path + ".keys.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_SAVEDISC=copy.adf: *SAVE a file onto that disc, then Save Disc Changes.
            if let discPath = env["MACARCH_SELFTEST_SAVEDISC"] {
                machine.insertDisc(URL(fileURLWithPath: discPath))
                machine.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); machine.keyUp(0x0C)
                try? await Task.sleep(for: .seconds(0.5))
                machine.type("*SAVE ADFS::0.$.SELFTEST 8000+100\n")
                try? await Task.sleep(for: .seconds(8))
                let before = machine.disc
                let saved = machine.saveDisc()
                try? "disc before save: \(before) saved=\(saved) after: modified=\(machine.disc.modified)\n"
                    .write(toFile: path + ".disc.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_RECORD=movie.mp4: record 3 s (with sound: a VDU 7 beep at the command line).
            if let movie = env["MACARCH_SELFTEST_RECORD"] {
                machine.startRecording(to: URL(fileURLWithPath: movie))
                machine.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); machine.keyUp(0x0C)
                try? await Task.sleep(for: .seconds(0.5))
                machine.type("VDU7\n")
                try? await Task.sleep(for: .seconds(3))
                machine.toggleRecording()
                try? await Task.sleep(for: .seconds(1))
            }
            // MACARCH_SELFTEST_HARDDISC=disc.hdf: become an ARM3 A440 (or the
            // MACARCH_SELFTEST_MODEL) with that new, formatted disc and
            // catalogue it. (Self-tests use their own settings and profiles.)
            if let hdPath = env["MACARCH_SELFTEST_HARDDISC"] {
                let model = env["MACARCH_SELFTEST_MODEL"].flatMap(MachineModel.init(rawValue:)) ?? .a440
                try? FileManager.default.removeItem(atPath: hdPath)
                let geometry = (model.hasIDE ? HardDiscGeometry.idePresets : HardDiscGeometry.presets)[0].geometry
                try? ADFSFormatter.createFormattedImage(path: hdPath, geometry: geometry, name: "SelfTest")
                machine.setHardware(model: model, cpu: model == .a440 ? .arm3 : model.defaultCPU, hardDiscs: [hdPath, nil])
                try? await Task.sleep(for: .seconds(wait))
                machine.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); machine.keyUp(0x0C)
                try? await Task.sleep(for: .seconds(0.5))
                machine.type("*Cat :4\n*Free :4\n")
                try? await Task.sleep(for: .seconds(4))
                let text = machine.host?.sendAndWait { String($0.machine.recentText.suffix(400)) } ?? ""
                try? "title=\(machine.title)\nmodel=\(machine.model.rawValue) cpu=\(machine.cpu.rawValue) ram=\(machine.ramKB) discs=\(machine.hardDiscs)\n\(text)\n"
                    .write(toFile: path + ".harddisc.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_REWIND=seconds: rewind, pause, and report the history.
            if let back = env["MACARCH_SELFTEST_REWIND"].flatMap(Double.init) {
                let before = await machine.rewindPoints()
                machine.rewind(seconds: back)
                machine.setPaused(true)
                try? await Task.sleep(for: .seconds(0.5))
                let after = await machine.rewindPoints()
                try? "points=\(before.points.count) now=\(before.now) -> points=\(after.points.count) now=\(after.now)\n"
                    .write(toFile: path + ".rewind.txt", atomically: true, encoding: .utf8)
            }
            // MACARCH_SELFTEST_OPEN="Item,Item": choose menu items (e.g. the MCP
            // windows), then capture every window to out-<n>.png.
            if let items = env["MACARCH_SELFTEST_OPEN"] {
                for title in items.split(separator: ",") {
                    @MainActor func find(_ menu: NSMenu) -> NSMenuItem? {
                        for i in menu.items {
                            if i.title == title { return i }
                            if let sub = i.submenu, let f = find(sub) { return f }
                        }
                        return nil
                    }
                    if let main = NSApp.mainMenu, let item = find(main), let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                for (n, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                    if let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(n).png")))
                    }
                }
            }
            // MACARCH_SELFTEST_NETWORK=TEMPLATE: make that network (in MACARCH_SELFTEST_NETWORK_DIR, else a
            // temporary folder), open its studio (MACARCH_SELFTEST_NETWORK_MODE: canvas, tiles, focus, traffic or mandelbrot),
            // let it run, and capture it (-network.png) with a report (.network.txt). MACARCH_SELFTEST_NETWORK_SEND=1
            // has station 1 send station 2 a message through RISC OS's Econet SWIs first.
            if let template = env["MACARCH_SELFTEST_NETWORK"].flatMap(NetworkTemplate.init(rawValue:)) {
                await networkSelfTest(template, path: path, env: env)
            }
            // MACARCH_SELFTEST_CONFIGURE=1 (or a model, to show it chosen): open Configure Machine at its usual size and capture it
            // (MACARCH_SELFTEST_CONFIGURE_TAB picks the tab: model, processor, monitor, rom, hardDiscs).
            if env["MACARCH_SELFTEST_CONFIGURE"] != nil {
                machine.configureRequested = true
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Configure —") && $0.isVisible }) {
                    // MACARCH_SELFTEST_CONFIGURE_HEIGHT asks for another height (to check it's clamped).
                    let height = env["MACARCH_SELFTEST_CONFIGURE_HEIGHT"].flatMap(Double.init) ?? 640
                    window.setFrame(NSRect(x: 40, y: 40, width: 760, height: height), display: true)
                    try? await Task.sleep(for: .seconds(1))
                    try? "asked \(height), got \(window.frame.height)\n".write(toFile: path + ".configure.txt", atomically: true, encoding: .utf8)
                    if let frameView = window.contentView?.superview,
                       let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-configure.png")))
                    }
                    // And scrolled to the end.
                    @MainActor func scrollView(_ v: NSView) -> NSScrollView? {
                        if let s = v as? NSScrollView { return s }
                        for sub in v.subviews { if let s = scrollView(sub) { return s } }
                        return nil
                    }
                    if let content = window.contentView, let sv = scrollView(content), let doc = sv.documentView {
                        doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.maxY : 0))
                        try? await Task.sleep(for: .seconds(1))
                        if let frameView = window.contentView?.superview,
                           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                            frameView.cacheDisplay(in: frameView.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-configure-end.png")))
                        }
                    }
                }
            }
            // MACARCH_SELFTEST_WHATSNEW=VERSION: the last version run; the window opens if there's news.
            if env["MACARCH_SELFTEST_WHATSNEW"] != nil,
               let window = NSApp.windows.first(where: { $0.title == "What's New" && $0.isVisible }),
               let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-whatsnew.png")))
            }
            var text = ""
            @MainActor func walk(_ menu: NSMenu, _ depth: Int) {
                // SwiftUI refreshes menu items as a menu opens.
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                for item in menu.items {
                    let pad = String(repeating: "  ", count: depth)
                    if item.isSeparatorItem { text += pad + "---\n"; continue }
                    var key = ""
                    if !item.keyEquivalent.isEmpty {
                        let m = item.keyEquivalentModifierMask
                        key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") +
                            (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent
                    }
                    text += pad + item.title + (key.isEmpty ? "" : "  [\(key)]") + (item.isEnabled ? "" : "  (disabled)") +
                        (item.state == .on ? "  ✓" : "") + "\n"
                    if let sub = item.submenu { walk(sub, depth + 1) }
                }
            }
            if let main = NSApp.mainMenu { walk(main, 0) }
            try? text.write(toFile: path + ".menus.txt", atomically: true, encoding: .utf8)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) ?? NSApp.windows.first,
               let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                // Metal content is not in a cached display: draw the picture in.
                if let view = window.contentView?.firstSubview(of: EmulatorNSView.self), let r = machine.renderer {
                    let f = view.convert(view.bounds, to: frameView)
                    let scale = CGFloat(rep.pixelsWide) / frameView.bounds.width
                    if let img = r.renderImage(width: Int(f.width * scale), height: Int(f.height * scale)) {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        NSImage(cgImage: img, size: f.size).draw(in: f)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-window.png")))
                try? "title=\(window.title) subtitle=\(window.subtitle) size=\(window.frame.size) content=\(window.contentLayoutRect.size) zoom=\(machine.zoom.map { String($0) } ?? "none") active=\(NSApp.isActive) key=\(window.isKeyWindow) guest=\(String(format: "%.1f", machine.host?.guestSeconds ?? 0)) wall=\(String(format: "%.1f", Date().timeIntervalSince(launched)))\n"
                    .write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            }
            if let r = machine.renderer, let image = r.renderImage(width: Int(r.actualSize.width), height: Int(r.actualSize.height)),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-display.png")))
            }
            NSApp.terminate(nil)
        }
    }

    private static func networkSelfTest(_ template: NetworkTemplate, path: String, env: [String: String]) async {
        let folder = env["MACARCH_SELFTEST_NETWORK_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacArch self-test")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(template.title).appendingPathExtension(NetworkPackage.fileExtension)
        try? FileManager.default.removeItem(at: url)
        var report = ""
        do { try NetworkPackage.create(template, at: url) } catch { report += "create failed: \(error)\n" }
        NotificationCenter.default.post(name: NetworkStudioCommands.openRequest, object: url)
        var seconds = Double(env["MACARCH_SELFTEST_NETWORK_SECONDS"] ?? "") ?? 30
        // MACARCH_SELFTEST_NETWORK_FAST=1: as fast as the Mac can go (to measure).
        if env["MACARCH_SELFTEST_NETWORK_FAST"] != nil {
            try? await Task.sleep(for: .seconds(1))
            seconds -= 1
            NetworkSession.opened(url)?.network.setSpeedLimited(false)
        }
        // MACARCH_SELFTEST_LEVEL4=<Level 4 disc image>: the file server is set up from it.
        if let disc = env["MACARCH_SELFTEST_LEVEL4"] {
            try? await Task.sleep(for: .seconds(2))
            seconds -= 2
            if let session = NetworkSession.opened(url), let server = session.project.nodes.first(where: { $0.kind == .fileServer }) {
                do { try session.setUpLevel4(server.id, disc: URL(fileURLWithPath: disc)); report += "level 4 set up\n" } catch { report += "level 4: \(error)\n" }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        guard let session = NetworkSession.opened(url) else {
            report += "no session; open: \(NetworkSession.open.keys.map(\.path)); windows: \(NSApp.windows.map(\.title))\n"
            try? report.write(toFile: path + ".network.txt", atomically: true, encoding: .utf8)
            return
        }
        if env["MACARCH_SELFTEST_NETWORK_SEND"] != nil {
            let on = session.project.stations.compactMap { node in session.controllers[node.id].map { (node, $0) } }
            if on.count >= 2 {
                let (a, b) = (on[0].1, on[1].1)
                for c in [a, b] {
                    c.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); c.keyUp(0x0C)
                }
                try? await Task.sleep(for: .seconds(1))
                for c in [a, b] { c.type("BASIC\n") }
                try? await Task.sleep(for: .seconds(2))
                b.type("DIM B% 64:SYS &40000,&77,\(on[0].0.stationNumber ?? 1),0,B%,64 TO H%\n")
                try? await Task.sleep(for: .seconds(4))
                a.type("DIM B% 64:$B%=\"HELLO\":SYS &40009,&80,&77,\(on[1].0.stationNumber ?? 2),0,B%,6,10,100 TO S%:PRINT \"SENT \";S%\n")
                try? await Task.sleep(for: .seconds(5))
                b.type("SYS &40001,H% TO S%:PRINT \"GOT \";S%;\" \";$B%\n")
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // With Level 4 set up, the first station logs on and catalogues the server.
        if env["MACARCH_SELFTEST_LEVEL4"] != nil,
           let client = session.project.stations.first(where: { $0.kind == .station }).flatMap({ session.controllers[$0.id] }) {
            client.keyDown(0x0C); try? await Task.sleep(for: .milliseconds(100)); client.keyUp(0x0C)
            try? await Task.sleep(for: .seconds(1))
            client.type("NET\n")
            try? await Task.sleep(for: .seconds(1))
            client.type("I AM SYST\n")
            try? await Task.sleep(for: .seconds(4))
            client.type("CAT\n")
            try? await Task.sleep(for: .seconds(4))
        }
        // MACARCH_SELFTEST_MANDEL=<seconds>: the Distributed Mandelbrot demo: Mandel typed on the Guide (booted
        // and logged on by then), which has that long to draw before the capture.
        if let wait = env["MACARCH_SELFTEST_MANDEL"].flatMap(Double.init),
           let guide = session.project.stations.first(where: { $0.waitsForServer == true }).flatMap({ session.controllers[$0.id] }) {
            guide.type("Mandel\n")
            try? await Task.sleep(for: .seconds(wait))
        }
        let status = session.network.status
        report += "machines on: \(session.controllers.count) of \(session.project.stations.count)\n"
        report += String(format: "speed: %.2f on %d threads\n", status.speed, status.threads)
        report += "frames: \(session.network.frames().map { "\($0.transmitter):\($0.kind.rawValue)" }.joined(separator: " "))\n"
        for node in session.project.stations {
            guard let host = session.controllers[node.id]?.host else { report += "\(node.name): off\n"; continue }
            let text = host.sendAndWait { s in s.machine.screenText.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(4) }
            report += "\(node.name) (\(node.stationNumber ?? 0)):\n  " + text.joined(separator: "\n  ") + "\n"
        }
        try? report.write(toFile: path + ".network.txt", atomically: true, encoding: .utf8)
        if let window = NSApp.windows.first(where: { $0.title == session.project.name && $0.isVisible }) {
            window.setFrame(NSRect(x: 40, y: 40, width: 1180, height: 780), display: true)
            try? await Task.sleep(for: .seconds(1.5))
            if let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-network.png")))
            }
            // The live pictures (Metal views, which the capture above leaves black), as each draws itself.
            for (n, view) in (window.contentView?.allSubviews(of: EmulatorNSView.self) ?? []).enumerated() {
                if let image = view.renderer?.renderImage(width: 416, height: 312) {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-tile\(n).png")))
                }
            }
        }
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { v -> [T] in ((v as? T).map { [$0] } ?? []) + v.allSubviews(of: type) }
    }

    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstSubview(of: type) { return t }
        }
        return nil
    }

}
