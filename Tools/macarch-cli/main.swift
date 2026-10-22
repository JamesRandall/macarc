import ArchimedesCore
import Foundation

// macarch-cli: deterministic headless runner and diagnostics.
//
//   macarch-cli run --rom <file|dir> [--disc img] [--seconds N | --frames N]
//                   [--screenshot out.png] [--cmos file] [--save-cmos file]
//                   [--reset-at SECONDS] [--model A440/1] [--cpu ARM3] [--hard-disc file.hdf ...]
//                   [--cmos-reset] [--type TEXT --type-at SECONDS] [--key NAME@SECONDS ...]
//                   [--trace-tail N] [--json] [--wav out.wav]
//                   [--load-snapshot file] [--save-snapshot file]
//   macarch-cli snapshot-info <file>
//
// With --load-snapshot, the machine resumes from the snapshot (its discs are
// reopened from their recorded paths, or --disc if the SHA-256 matches) and
// every @SECONDS time is relative to the snapshot point.
//   macarch-cli assemble <source.s> [-o out.bin] [--symbols out.sym] [--list]
//   macarch-cli disk-inspect <image>
//   macarch-cli rom-info <file|dir>
//   macarch-cli manifest <directory>
//
// Exit codes: 0 success, 1 usage error, 2 ROM/config error, 3 media error, 4 run stopped abnormally.

func fail(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: macarch-cli run|assemble|disk-inspect|rom-info|manifest|snapshot-info|hard-disc-create|hard-disc-add ...", code: 1)
}
args.removeFirst()

func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func values(_ name: String) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count { if args[i] == name, i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 } }
    return out
}
func flag(_ name: String) -> Bool { args.contains(name) }

/// Captures VIDC output, resampled to 48 kHz as the app plays it, into a
/// 16-bit stereo WAV.
final class WAVCapture: AudioSink {
    var samples: [Int16] = []
    let rate: Double = 48_000
    var resampler = BoxResampler(outputRate: 48_000)
    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double) {
        resampler.push(left: left, right: right, inputRate: sampleRate) { l, r in
            samples.append(Int16(l * 32767)); samples.append(Int16(r * 32767))
        }
    }
    func write(to path: String) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let r = UInt32(rate.rounded()), bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(r); u32(r * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: URL(fileURLWithPath: path))
    }
}

switch command {
case "assemble":
    // assemble <source.s> [-o out.bin] [--symbols out.sym] [--list]: the
    // ARM assembler the debugger and agents use. Errors go to stderr as
    // file:line: message.
    guard let p = args.first, !p.hasPrefix("-") else { fail("assemble <source.s> [-o out.bin] [--symbols out.sym] [--list]", code: 1) }
    let a: ARMAssembler.Assembly
    do { a = try ARMAssembler.assemble(file: p) } catch { fail("\(error)", code: 3) }
    for w in a.warnings { FileHandle.standardError.write("\(w.location): warning: \(w.message)\n".data(using: .utf8)!) }
    let out = value("-o") ?? ((p as NSString).deletingPathExtension + ".bin")
    do { try Data(a.bytes).write(to: URL(fileURLWithPath: out)) } catch { fail("\(error)", code: 3) }
    if let sym = value("--symbols") {
        let text = a.symbols.byName.sorted { $0.value < $1.value }.map { String(format: "%@ = &%X", $0.key, $0.value) }.joined(separator: "\n")
        do { try (text + "\n").write(toFile: sym, atomically: true, encoding: .utf8) } catch { fail("\(error)", code: 3) }
    }
    if flag("--list") {
        for offset in stride(from: 0, to: a.bytes.count - 3, by: 4) {
            let address = a.origin &+ UInt32(offset)
            let w = UInt32(a.bytes[offset]) | UInt32(a.bytes[offset + 1]) << 8 | UInt32(a.bytes[offset + 2]) << 16 | UInt32(a.bytes[offset + 3]) << 24
            for n in a.symbols.names(at: address) { print("\(n):") }
            let line = a.symbols.location(at: address).map { "  ; \($0)" } ?? ""
            print(String(format: "%08X  %08X  ", address, w) + Disassembler.disassemble(w, at: address, symbols: a.symbols) + line)
        }
    }
    print(String(format: "%@: %d bytes at &%X, entry &%X", out, a.bytes.count, a.origin, a.entry))

case "disk-inspect":
    guard let p = args.first else { fail("disk-inspect <image>", code: 1) }
    do { print(JSON.encode(try ADFSInspector.inspect(path: p))) } catch { fail("\(error)", code: 3) }

case "hard-disc-create":
    // hard-disc-create <file> [cylinders heads [sectors]] [--ide] [--blank]  (default ST506 615 x 4, 20 MB; IDE 977 x 5 x 17, 40 MB; formatted)
    guard let p = args.first else { fail("hard-disc-create <file> [cylinders heads]", code: 1) }
    // hard-disc-create <file> --ide [cylinders heads sectors]: an IDE drive (512-byte sectors)
    // hard-disc-create <file> ... --from <zip or folder>: formatted, with those files in $
    let ide = flag("--ide")
    let source = value("--from")
    let nums = args.dropFirst().filter { $0 != source }.compactMap { Int($0) }
    let g = ide ? HardDiscGeometry(cylinders: nums.count > 0 ? nums[0] : 977, heads: nums.count > 1 ? nums[1] : 5,
                                   sectorsPerTrack: nums.count > 2 ? nums[2] : 17, sectorSize: 512)
                : HardDiscGeometry(cylinders: nums.count > 0 ? nums[0] : 615, heads: nums.count > 1 ? nums[1] : 4)
    do {
        if let source {
            let items = try ADFSHardDiscBuilder.items(from: source)
            try ADFSHardDiscBuilder.create(path: p, geometry: g, name: "HardDisc4", items: items)
            FileHandle.standardError.write("\(items.count) files from \(source)\n".data(using: .utf8)!)
        } else if flag("--blank") { try HardDiscImage.create(path: p, geometry: g) } else { try ADFSFormatter.createFormattedImage(path: p, geometry: g, name: "HardDisc4") }
    } catch { fail("\(error)", code: 3) }
    print(p)

case "hard-disc-add":
    // hard-disc-add <file> <zip or folder>...: copies the files onto an existing old-map drive
    guard args.count >= 2 else { fail("hard-disc-add <file> <zip or folder>...", code: 1) }
    do {
        let items = try args.dropFirst().flatMap { try ADFSHardDiscBuilder.items(from: $0) }
        let s = try ADFSHardDiscWriter.add(path: args[0], items: items)
        print(JSON.encode(["added": s.added.joined(separator: " "), "replaced": s.replaced.joined(separator: " "),
                           "directoriesMade": s.directoriesMade.joined(separator: " "), "bytesFree": String(s.bytesFree)]))
    } catch { fail("\(error)", code: 3) }

case "rom-info":
    do {
        let r = try ROMImage.load(paths: args)
        print(JSON.encode(["version": r.versionString, "sha256": r.sha256, "size": String(r.data.count), "layout": r.layoutNote, "sources": r.sources.joined(separator: ", ")]))
    } catch { fail("\(error)", code: 2) }

case "snapshot-info":
    guard let p = args.first, let d = FileManager.default.contents(atPath: p) else { fail("snapshot-info <file>", code: 1) }
    do { print(JSON.encode(try Snapshot.header(of: [UInt8](d)))) } catch { fail("\(error)", code: 4) }

case "manifest":
    guard let dir = args.first else { fail("manifest <directory>", code: 1) }
    let fm = FileManager.default
    var rows: [[String: String]] = []
    if let e = fm.enumerator(atPath: dir) {
        for case let rel as String in e {
            let p = (dir as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
            let lower = rel.lowercased()
            if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".pdf") || lower.hasSuffix(".ds_store") { continue }
            guard let d = fm.contents(atPath: p) else { continue }
            let det = MediaDetector.detect([UInt8](d))
            rows.append(["path": rel, "size": String(d.count), "sha256": SHA256.hex([UInt8](d)), "format": det.format, "notes": det.notes])
        }
    }
    print(JSON.encode(rows))

case "run":
    var config = MachineConfiguration()
    if let name = value("--model") {
        guard let m = MachineModel.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() || $0.rawValue.lowercased().hasPrefix(name.lowercased() + "/") }) else {
            fail("unknown model \(name); choose from " + MachineModel.allCases.map(\.rawValue).joined(separator: ", "), code: 1)
        }
        config = MachineConfiguration(model: m)
    }
    if let c = value("--cpu") {
        guard let t = CPUType(rawValue: c.uppercased()) else { fail("unknown CPU \(c) (ARM2, ARM3 or ARM250)", code: 1) }
        config.cpu = t
    }
    for h in values("--hard-disc") { config.hardDiscs.append(h) }
    config.romPaths = values("--rom")
    if let ram = value("--ram-kb"), let k = Int(ram) { config.ramKB = k }
    if let c = value("--cmos") { config.cmosPath = c }
    if flag("--cmos-reset") { config.powerOnKeys = [0x34] } // hold Delete at power-on
    let machine: Machine
    var disc: FloppyImage?
    if let path = value("--disc") {
        do { disc = try FloppyImage.open(path: path, writeProtected: flag("--write-protect")) } catch { fail("\(error)", code: 3) }
    }
    if let snap = value("--load-snapshot") {
        guard let d = FileManager.default.contents(atPath: snap) else { fail("cannot read snapshot \(snap)", code: 3) }
        do {
            let rom = try ROMImage.load(paths: config.romPaths)
            machine = try Machine.restore(snapshot: [UInt8](d), rom: rom) { media in
                if let disc, disc.sha256 == media.sha256 { return disc }
                return Machine.reopenDisc(media)
            }
        } catch { fail("\(error)", code: 4) }
    } else {
        do { machine = try Machine(configuration: config) } catch { fail("\(error)", code: 2) }
        if let disc { machine.insertFloppy(disc) }
        machine.powerOn()
    }
    /// Guest tick for a script time in seconds (relative to the start point).
    let base = machine.nominalTicks
    func at(_ seconds: Double) -> UInt64 { base &+ UInt64(seconds * 24_000_000) }
    if let w = value("--watch-page").flatMap({ UInt32($0.replacingOccurrences(of: "&", with: ""), radix: 16) }) { machine.memc.watchedPage = w }
    if let text = value("--type") {
        let t = Double(value("--type-at") ?? "0") ?? 0
        machine.scheduleTyping(text.replacingOccurrences(of: "\\n", with: "\n"), startingAt: at(t))
    }
    for k in values("--key") {
        // NAME@SECONDS[:DURATION_MS]
        let parts = k.split(separator: "@")
        guard parts.count == 2, let code = ArcKey.names[String(parts[0]).lowercased()] else { fail("bad --key \(k)", code: 1) }
        let tp = parts[1].split(separator: ":")
        let t = at(Double(tp[0]) ?? 0)
        let dur = UInt64(tp.count > 1 ? (Int(tp[1]) ?? 100) : 100) * 24_000
        machine.schedule(.init(tick: t, action: .keyDown(code)))
        machine.schedule(.init(tick: t + dur, action: .keyUp(code)))
    }
    // --watch-logical HEXADDR,LEN: log writes to the physical RAM behind a logical range (as mapped at the start).
    if let w = value("--watch-logical") {
        let parts = w.split(separator: ",")
        if parts.count == 2, let a = UInt32(parts[0], radix: 16), let n = UInt32(parts[1], radix: 16) {
            let cpu = machine.cpu
            machine.watchLogical = (a, n)
            machine.memc.watchHit = { p, v in
                FileHandle.standardError.write(String(format: "write phys %06X = %08X pc %08X t=%.4f\n", p, v, cpu.currentInstructionAddress, Double(machine.memc.ticks) / 24e6).data(using: .utf8)!)
            }
        }
    }
    for b in values("--break") {
        // HEXADDR, or any debugger expression (e.g. "Vector_IRQVector")
        let a = UInt32(b.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? (try? machine.debugger.evaluate(b))
        if let a { _ = try? machine.debugger.addBreakpoint(.init(id: 0, kind: .execute, start: a & ~3)) }
    }
    for mv in values("--mouse") {
        // DX,DY@SECONDS  (mouse counts, +y up)
        let parts = mv.split(separator: "@")
        let xy = parts[0].split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, xy.count == 2, let t = Double(parts[1]) else { fail("bad --mouse \(mv)", code: 1) }
        // Deliver in small steps as a real mouse would.
        var rx = xy[0], ry = xy[1], tick = at(t)
        while rx != 0 || ry != 0 {
            let sx = max(-20, min(20, rx)), sy = max(-20, min(20, ry))
            machine.schedule(.init(tick: tick, action: .mouseMove(sx, sy)))
            rx -= sx; ry -= sy; tick += 480_000
        }
    }
    for c in values("--click") {
        // select|menu|adjust@SECONDS
        let parts = c.split(separator: "@")
        guard parts.count == 2, let code = ArcKey.names[String(parts[0])], let t = Double(parts[1]) else { fail("bad --click \(c)", code: 1) }
        let tick = at(t)
        machine.schedule(.init(tick: tick, action: .keyDown(code)))
        machine.schedule(.init(tick: tick + 2_400_000, action: .keyUp(code)))
    }
    for v in values("--swi-log") {
        for h in v.split(separator: ",") { if let n = UInt32(h.replacingOccurrences(of: "&", with: ""), radix: 16) { machine.swiLogFilter.insert(n) } }
    }
    if let n = value("--vidc-log").flatMap({ Int($0) }) {
        machine.vidc.registerLog = RingBuffer(capacity: n)
        let vidc = machine.vidc, cpu = machine.cpu
        machine.ioc.eventTrace = { s in vidc.registerLog?.append(String(format: "frame %llu line %d pc %08X ", vidc.frameCount, vidc.raster, cpu.pc) + s) }
    }
    let wav = value("--wav").map { _ in WAVCapture() }
    machine.vidc.audioSink = wav
    let traceTail = Int(value("--trace-tail") ?? "0") ?? 0
    if traceTail > 0 { machine.debugger.setTracing(traceTail) }
    let start = Date()
    var reason: Machine.StopReason = .completed
    if let f = value("--frames"), let n = Int(f) {
        reason = machine.runFrames(n, maxSeconds: Double(n) / 25 + 5)
    } else {
        let s = Double(value("--seconds") ?? "1") ?? 1
        if let r = value("--reset-at").flatMap(Double.init), r < s {
            machine.run(seconds: r)
            machine.reset()
            reason = machine.run(seconds: s - r)
        } else {
            reason = machine.run(seconds: s)
        }
    }
    let wall = Date().timeIntervalSince(start)
    let frame = machine.currentFrame
    var out: [String: String] = [
        "stop": "\(reason)", "guestSeconds": String(format: "%.3f", machine.seconds), "wallSeconds": String(format: "%.3f", wall),
        "speed": String(format: "%.2fx", machine.seconds / max(wall, 0.0001)),
        "instructions": String(machine.cpu.instructionCount), "pc": hex32(machine.cpu.pc), "mode": machine.cpu.mode.description,
        "frame": "\(frame.width)x\(frame.height) #\(frame.frameNumber)", "frameChecksum": String(format: "%016llX", frame.checksum),
        "rom": machine.rom.versionString, "romSHA256": machine.rom.sha256,
        "pointer": "\(machine.vidc.pointerPosition.x),\(machine.vidc.pointerPosition.y)",
        "pendingInput": String(machine.pendingInputEvents),
    ]
    if let shot = value("--screenshot") {
        let png = PNGEncoder.encode(frame, scaleX: frame.scaleX, scaleY: frame.scaleY)
        do { try png.write(to: URL(fileURLWithPath: shot)); out["screenshot"] = shot } catch { out["screenshotError"] = "\(error)" }
    }
    if let spec = value("--dump") {
        // START,LENGTH,FILE (hex start/length, logical addresses; unmapped reads as zero)
        let f = spec.split(separator: ",")
        if f.count == 3, let a = UInt32(f[0].replacingOccurrences(of: "0x", with: ""), radix: 16), let n = UInt32(f[1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
            var bytes = [UInt8](repeating: 0, count: Int(n))
            for i in 0..<Int(n) { bytes[i] = machine.memc.debugRead(a &+ UInt32(i), space: .logical) ?? 0 }
            try? Data(bytes).write(to: URL(fileURLWithPath: String(f[2]))); out["dump"] = String(f[2])
        }
    }
    for spec in values("--disasm") {
        // ADDR,COUNT (hex address)
        let f = spec.split(separator: ",")
        if f.count == 2, let a = UInt32(f[0].replacingOccurrences(of: "0x", with: ""), radix: 16), let n = Int(f[1]) {
            for l in machine.disassemble(at: a, count: n) { print(l) }
        }
    }
    if flag("--floppy-trace") { for e in machine.fdc.trace.elements { print("fdc", e.description) } }
    if let log = machine.vidc.registerLog {
        for l in log.elements { print(l) }
        print("display timing:", machine.vidc.timingSummary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
    if !machine.swiLogFilter.isEmpty { for l in machine.swiLog.elements { print(l) } }
    if let wav, let p = value("--wav") {
        do { try wav.write(to: p); out["wav"] = p; out["wavRate"] = String(format: "%.0f", wav.rate) } catch { out["wavError"] = "\(error)" }
    }
    if let save = value("--save-cmos") { try? machine.saveCMOS(to: save) }
    if let p = value("--save-snapshot") {
        do { try Data(machine.snapshot(createdBy: "macarch-cli")).write(to: URL(fileURLWithPath: p)); out["snapshot"] = p } catch { out["snapshotError"] = "\(error)" }
    }
    print(JSON.encode(out))
    if flag("--diagnostics") { print(JSON.encode(machine.diagnostics())) }
    if traceTail > 0 {
        for e in machine.debugger.trace?.last(traceTail) ?? [] where e.interrupt == nil {
            print(String(format: "%08X  %08X  %@", e.pc, e.instruction, Disassembler.disassemble(e.instruction, at: e.pc)))
        }
    }
    if flag("--text") { print(machine.recentText) }
    if flag("--screen-text") { print(machine.screenText.joined(separator: "\n")) }
    if flag("--cam") { for l in machine.memc.camLog.elements { print(l) } }
    if flag("--registers") { print(JSON.encode(machine.registerDump(banked: true))) }
    for l in machine.memc.pageWatchLog { print("page", l) }
    if flag("--hardware") {
        for section in machine.hardwareState {
            print(section.name)
            for row in section.rows { print("  \(row.label): \(row.value)") }
        }
    }
    exit(reason == .completed ? 0 : 4)

default:
    fail("unknown command \(command)", code: 1)
}
