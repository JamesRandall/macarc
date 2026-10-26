#if arch(wasm32)
import ArchimedesEmbedding

// The WebAssembly ABI: flat functions over integers and linear-memory
// buffers, so any host (a browser, a Worker, Node, workerd) can drive a
// machine without bindings. Documented in docs/wasm.md; web/src/arc-wasm.ts
// wraps it.
//
// Conventions:
// - Machines are opaque handles (positive Int32s). An unknown handle is
//   error -1, never a trap.
// - Calls that can fail return 0 (or a positive value) on success and a
//   negative error code on failure; `arc_error_ptr/len` then holds a UTF-8
//   message, valid until the next failing call.
// - Input bytes: the host gets a buffer from `arc_alloc`, fills it, passes
//   pointer and length, and frees it with `arc_free` afterwards (the callee
//   copies what it keeps).
// - Output bytes (snapshots, memory, audio, floppy contents) go in one
//   module-owned result buffer, `arc_result_ptr/len`, valid until the next
//   call that produces output. The frame buffer is per machine and valid
//   until the next `arc_frame_update` or `arc_release` of that machine.

/// Bumped when a signature or meaning changes.
let abiVersion: Int32 = 1

enum ErrorCode {
    static let badHandle: Int32 = -1
}

nonisolated(unsafe) var machines: [Int32: EmbeddedMachine] = [:]
nonisolated(unsafe) var nextHandle: Int32 = 1
nonisolated(unsafe) var errorText: [UInt8] = []
nonisolated(unsafe) var result: [UInt8] = []
nonisolated(unsafe) var audioResult: [Float] = []

func fail(_ code: Int32, _ message: String) -> Int32 {
    errorText = Array(message.utf8)
    return code
}

func fail(_ error: Error) -> Int32 {
    if let f = error as? EmbeddedMachine.Failure { return fail(-f.code, f.description) }
    return fail(-99, "\(error)")
}

func bytes(_ p: UnsafeRawPointer?, _ n: Int32) -> [UInt8]? {
    guard n >= 0, n <= Int32(EmbeddedMachine.maxInputBytes) else { return nil }
    guard n > 0 else { return [] }
    guard let p else { return nil }
    return Array(UnsafeRawBufferPointer(start: p, count: Int(n)))
}

func with(_ h: Int32, _ body: (EmbeddedMachine) throws -> Int32) -> Int32 {
    guard let m = machines[h] else { return fail(ErrorCode.badHandle, "no machine \(h)") }
    do { return try body(m) } catch { return fail(error) }
}

func setResult(_ b: [UInt8]) -> Int32 {
    result = b
    return Int32(b.count)
}

// MARK: Module

@_expose(wasm, "arc_abi_version")
@_cdecl("arc_abi_version")
public func arc_abi_version() -> Int32 { abiVersion }

@_expose(wasm, "arc_alloc")
@_cdecl("arc_alloc")
public func arc_alloc(_ n: Int32) -> UnsafeMutableRawPointer? {
    guard n > 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(n), alignment: 16)
}

@_expose(wasm, "arc_free")
@_cdecl("arc_free")
public func arc_free(_ p: UnsafeMutableRawPointer?) { p?.deallocate() }

@_expose(wasm, "arc_error_ptr")
@_cdecl("arc_error_ptr")
public func arc_error_ptr() -> UnsafeRawPointer? { errorText.withUnsafeBytes { $0.baseAddress } }

@_expose(wasm, "arc_error_len")
@_cdecl("arc_error_len")
public func arc_error_len() -> Int32 { Int32(errorText.count) }

@_expose(wasm, "arc_result_ptr")
@_cdecl("arc_result_ptr")
public func arc_result_ptr() -> UnsafeRawPointer? { result.withUnsafeBytes { $0.baseAddress } }

@_expose(wasm, "arc_result_len")
@_cdecl("arc_result_len")
public func arc_result_len() -> Int32 { Int32(result.count) }

@_expose(wasm, "arc_ticks_per_second")
@_cdecl("arc_ticks_per_second")
public func arc_ticks_per_second() -> Int32 { Int32(EmbeddedMachine.ticksPerSecond) }

@_expose(wasm, "arc_machine_count")
@_cdecl("arc_machine_count")
public func arc_machine_count() -> Int32 { Int32(machines.count) }

// MARK: Machines

/// `model`: a MachineModel name ("A3000"); `ramKB` 0 for its usual; ROM bytes.
/// Returns a handle, or a negative error.
@_expose(wasm, "arc_create")
@_cdecl("arc_create")
public func arc_create(_ model: UnsafeRawPointer?, _ modelLen: Int32, _ ramKB: Int32, _ cmosReset: Int32,
                       _ rom: UnsafeRawPointer?, _ romLen: Int32) -> Int32 {
    guard let name = bytes(model, modelLen), let romBytes = bytes(rom, romLen) else { return fail(-2, "bad buffer") }
    do {
        let m = try EmbeddedMachine(model: String(decoding: name, as: UTF8.self), ramKB: Int(ramKB),
                                    cmosReset: cmosReset != 0, rom: romBytes)
        let h = nextHandle
        nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
        machines[h] = m
        return h
    } catch { return fail(error) }
}

@_expose(wasm, "arc_release")
@_cdecl("arc_release")
public func arc_release(_ h: Int32) -> Int32 {
    machines.removeValue(forKey: h) == nil ? fail(ErrorCode.badHandle, "no machine \(h)") : 0
}

@_expose(wasm, "arc_power_on")
@_cdecl("arc_power_on")
public func arc_power_on(_ h: Int32) -> Int32 { with(h) { $0.powerOn(); return 0 } }

@_expose(wasm, "arc_reset")
@_cdecl("arc_reset")
public func arc_reset(_ h: Int32) -> Int32 { with(h) { $0.reset(); return 0 } }

/// Runs `ticks` (24 MHz) of guest time. Returns the stop reason: 0
/// completed, 1 debugger stop, 2 instruction budget.
@_expose(wasm, "arc_run")
@_cdecl("arc_run")
public func arc_run(_ h: Int32, _ ticks: Int32) -> Int32 {
    with(h) { m in
        guard ticks >= 0 else { throw EmbeddedMachine.Failure.badArgument("ticks \(ticks)") }
        switch try m.run(ticks: UInt64(ticks)) {
        case .completed: return 0
        case .stopped: return 1
        case .instructionBudget, .frameLimit: return 2
        }
    }
}

/// Guest time in ticks (as a double: exact to 2^53).
@_expose(wasm, "arc_ticks")
@_cdecl("arc_ticks")
public func arc_ticks(_ h: Int32) -> Double { machines[h].map { Double($0.ticks) } ?? -1 }

@_expose(wasm, "arc_frame_count")
@_cdecl("arc_frame_count")
public func arc_frame_count(_ h: Int32) -> Double { machines[h].map { Double($0.frameCount) } ?? -1 }

@_expose(wasm, "arc_pc")
@_cdecl("arc_pc")
public func arc_pc(_ h: Int32) -> Int32 { machines[h].map { Int32(bitPattern: $0.cpuPC) } ?? 0 }

// MARK: Input

@_expose(wasm, "arc_key")
@_cdecl("arc_key")
public func arc_key(_ h: Int32, _ code: Int32, _ down: Int32) -> Int32 {
    with(h) { try $0.key(Int(code), down: down != 0); return 0 }
}

@_expose(wasm, "arc_mouse_move")
@_cdecl("arc_mouse_move")
public func arc_mouse_move(_ h: Int32, _ dx: Int32, _ dy: Int32) -> Int32 {
    with(h) { $0.mouseMove(dx: Int(dx), dy: Int(dy)); return 0 }
}

@_expose(wasm, "arc_release_keys")
@_cdecl("arc_release_keys")
public func arc_release_keys(_ h: Int32) -> Int32 { with(h) { $0.releaseAllKeys(); return 0 } }

// MARK: Media

@_expose(wasm, "arc_insert_floppy")
@_cdecl("arc_insert_floppy")
public func arc_insert_floppy(_ h: Int32, _ drive: Int32, _ p: UnsafeRawPointer?, _ n: Int32, _ writeProtected: Int32) -> Int32 {
    with(h) { m in
        guard let b = bytes(p, n) else { throw EmbeddedMachine.Failure.badArgument("bad buffer") }
        try m.insertFloppy(b, drive: Int(drive), writeProtected: writeProtected != 0)
        return 0
    }
}

@_expose(wasm, "arc_eject_floppy")
@_cdecl("arc_eject_floppy")
public func arc_eject_floppy(_ h: Int32, _ drive: Int32) -> Int32 { with(h) { try $0.ejectFloppy(drive: Int(drive)); return 0 } }

/// The floppy's current contents (writes included) into the result buffer;
/// returns the length (0: no disc).
@_expose(wasm, "arc_floppy_contents")
@_cdecl("arc_floppy_contents")
public func arc_floppy_contents(_ h: Int32, _ drive: Int32) -> Int32 {
    with(h) { setResult($0.floppyContents(drive: Int(drive)) ?? []) }
}

/// Starts a Classic: its classics.json entry, then its floppies, packed as
/// [u32 little-endian length, bytes] for each. Returns 0 or an error.
@_expose(wasm, "arc_start_classic")
@_cdecl("arc_start_classic")
public func arc_start_classic(_ h: Int32, _ json: UnsafeRawPointer?, _ jsonLen: Int32, _ discs: UnsafeRawPointer?, _ discsLen: Int32) -> Int32 {
    with(h) { m in
        guard let j = bytes(json, jsonLen), let packed = bytes(discs, discsLen) else {
            throw EmbeddedMachine.Failure.badArgument("bad buffer")
        }
        var list: [[UInt8]] = []
        var p = 0
        while p < packed.count {
            guard p + 4 <= packed.count else { throw EmbeddedMachine.Failure.badArgument("truncated disc list") }
            let n = Int(packed[p]) | Int(packed[p + 1]) << 8 | Int(packed[p + 2]) << 16 | Int(packed[p + 3]) << 24
            guard n >= 0, p + 4 + n <= packed.count else { throw EmbeddedMachine.Failure.badArgument("truncated disc list") }
            list.append(Array(packed[(p + 4)..<(p + 4 + n)]))
            p += 4 + n
        }
        try m.startClassic(gameJSON: j, discs: list)
        return 0
    }
}

@_expose(wasm, "arc_classic_started")
@_cdecl("arc_classic_started")
public func arc_classic_started(_ h: Int32) -> Int32 { with(h) { $0.classicStarted ? 1 : 0 } }

// MARK: Video

/// Converts the latest frame to RGBA if it's new: 1 if it changed, 0 if not.
@_expose(wasm, "arc_frame_update")
@_cdecl("arc_frame_update")
public func arc_frame_update(_ h: Int32) -> Int32 { with(h) { $0.updateFrame() ? 1 : 0 } }

/// RGBA8, `arc_frame_width` x `arc_frame_height`, rows top first, no padding.
@_expose(wasm, "arc_frame_ptr")
@_cdecl("arc_frame_ptr")
public func arc_frame_ptr(_ h: Int32) -> UnsafeRawPointer? { machines[h]?.rgba.withUnsafeBytes { $0.baseAddress } }

@_expose(wasm, "arc_frame_width")
@_cdecl("arc_frame_width")
public func arc_frame_width(_ h: Int32) -> Int32 { Int32(machines[h]?.frameWidth ?? 0) }

@_expose(wasm, "arc_frame_height")
@_cdecl("arc_frame_height")
public func arc_frame_height(_ h: Int32) -> Int32 { Int32(machines[h]?.frameHeight ?? 0) }

/// Suggested pixel scaling for the monitor's aspect ratio.
@_expose(wasm, "arc_frame_scale_x")
@_cdecl("arc_frame_scale_x")
public func arc_frame_scale_x(_ h: Int32) -> Int32 { Int32(machines[h]?.frameScaleX ?? 1) }

@_expose(wasm, "arc_frame_scale_y")
@_cdecl("arc_frame_scale_y")
public func arc_frame_scale_y(_ h: Int32) -> Int32 { Int32(machines[h]?.frameScaleY ?? 1) }

/// The frame number the RGBA buffer holds.
@_expose(wasm, "arc_frame_number")
@_cdecl("arc_frame_number")
public func arc_frame_number(_ h: Int32) -> Double { machines[h].map { Double($0.rgbaFrameNumber) } ?? -1 }

/// The latest frame's FNV-1a checksum (as the native CLI prints it), as
/// 16 hex digits in the result buffer.
@_expose(wasm, "arc_frame_checksum")
@_cdecl("arc_frame_checksum")
public func arc_frame_checksum(_ h: Int32) -> Int32 {
    with(h) { m in
        let hex = String(m.frameChecksum, radix: 16, uppercase: true)
        return setResult(Array((String(repeating: "0", count: 16 - hex.count) + hex).utf8))
    }
}

// MARK: Audio

/// Resample sound to `rate` Hz (0: off).
@_expose(wasm, "arc_audio_rate")
@_cdecl("arc_audio_rate")
public func arc_audio_rate(_ h: Int32, _ rate: Int32) -> Int32 { with(h) { $0.setAudioRate(Double(max(0, rate))); return 0 } }

/// Takes the samples made since the last call: interleaved stereo float32
/// at `arc_audio_ptr`; returns the number of floats.
@_expose(wasm, "arc_audio_take")
@_cdecl("arc_audio_take")
public func arc_audio_take(_ h: Int32) -> Int32 {
    with(h) { m in
        audioResult = m.takeAudio()
        return Int32(audioResult.count)
    }
}

@_expose(wasm, "arc_audio_ptr")
@_cdecl("arc_audio_ptr")
public func arc_audio_ptr() -> UnsafeRawPointer? { audioResult.withUnsafeBytes { $0.baseAddress } }

// MARK: Memory and state

/// Reads guest memory (`logical` 1: through the MEMC's page table) into the result buffer.
@_expose(wasm, "arc_read_memory")
@_cdecl("arc_read_memory")
public func arc_read_memory(_ h: Int32, _ address: Int32, _ length: Int32, _ logical: Int32) -> Int32 {
    with(h) { setResult(try $0.readMemory(UInt32(bitPattern: address), count: Int(length), logical: logical != 0)) }
}

/// The machine's complete state into the result buffer; returns its length.
@_expose(wasm, "arc_save_state")
@_cdecl("arc_save_state")
public func arc_save_state(_ h: Int32) -> Int32 { with(h) { setResult($0.saveState()) } }

@_expose(wasm, "arc_restore_state")
@_cdecl("arc_restore_state")
public func arc_restore_state(_ h: Int32, _ p: UnsafeRawPointer?, _ n: Int32) -> Int32 {
    with(h) { m in
        guard let b = bytes(p, n) else { throw EmbeddedMachine.Failure.badArgument("bad buffer") }
        try m.restoreState(b)
        return 0
    }
}

/// Text RISC OS has printed lately, into the result buffer.
@_expose(wasm, "arc_recent_text")
@_cdecl("arc_recent_text")
public func arc_recent_text(_ h: Int32) -> Int32 { with(h) { setResult(Array($0.recentText.utf8)) } }

/// The ROM's version string, into the result buffer.
@_expose(wasm, "arc_rom_version")
@_cdecl("arc_rom_version")
public func arc_rom_version(_ h: Int32) -> Int32 { with(h) { setResult(Array($0.romVersion.utf8)) } }
#endif
