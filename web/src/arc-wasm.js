// A typed wrapper over ArchimedesWasm's flat ABI (see docs/wasm.md): it owns
// the buffer protocol, so hosts (the browser worker, Node tests, a Cloudflare
// Worker) never touch linear memory themselves.

import { createWasi } from './wasi-shim.js';

export const ABI_VERSION = 1;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class ArcError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

/** One instantiated module; it can hold any number of machines. */
export class ArcModule {
  /**
   * @param {WebAssembly.Module | BufferSource} source compiled module or its bytes
   * @param {{ log?: (line: string) => void }} [options]
   */
  static async load(source, options = {}) {
    const wasi = createWasi(options);
    const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    const instance = await WebAssembly.instantiate(module, wasi.imports);
    wasi.setMemory(instance.exports.memory);
    instance.exports._initialize();
    const m = new ArcModule(instance.exports);
    const v = m.x.arc_abi_version();
    if (v !== ABI_VERSION) throw new Error(`ArchimedesWasm ABI ${v}; this wrapper speaks ${ABI_VERSION}`);
    return m;
  }

  constructor(exports) { this.x = exports; }

  get memory() { return this.x.memory; }
  get ticksPerSecond() { return this.x.arc_ticks_per_second(); }
  get machineCount() { return this.x.arc_machine_count(); }

  /** Calls `fn(ptr, len)` with `bytes` copied into module memory, then frees it. */
  withBytes(bytes, fn) {
    if (bytes.length === 0) return fn(0, 0);
    const p = this.x.arc_alloc(bytes.length);
    if (!p) throw new ArcError(-2, `cannot allocate ${bytes.length} bytes`);
    try {
      new Uint8Array(this.x.memory.buffer, p, bytes.length).set(bytes);
      return fn(p, bytes.length);
    } finally {
      this.x.arc_free(p);
    }
  }

  check(r) {
    if (r >= 0) return r;
    const msg = decoder.decode(new Uint8Array(this.x.memory.buffer, this.x.arc_error_ptr(), this.x.arc_error_len()));
    throw new ArcError(r, msg);
  }

  /** A copy of the module's result buffer. */
  result(len) {
    return new Uint8Array(this.x.memory.buffer, this.x.arc_result_ptr(), len).slice();
  }

  /**
   * @param {{ rom: Uint8Array, model?: string, ramKB?: number, cmosReset?: boolean }} o
   * @returns {ArcMachine}
   */
  createMachine({ rom, model = 'A3000', ramKB = 0, cmosReset = true }) {
    const name = encoder.encode(model);
    const h = this.withBytes(name, (np, nl) => this.withBytes(rom, (rp, rl) =>
      this.check(this.x.arc_create(np, nl, ramKB, cmosReset ? 1 : 0, rp, rl))));
    return new ArcMachine(this, h);
  }
}

/** One emulated Archimedes. */
export class ArcMachine {
  constructor(mod, handle) { this.mod = mod; this.x = mod.x; this.handle = handle; }

  release() { this.mod.check(this.x.arc_release(this.handle)); this.handle = 0; }
  powerOn() { this.mod.check(this.x.arc_power_on(this.handle)); }
  reset() { this.mod.check(this.x.arc_reset(this.handle)); }

  /** Runs `ticks` (24 MHz) of guest time; returns the stop reason (0 completed). */
  run(ticks) { return this.mod.check(this.x.arc_run(this.handle, ticks)); }
  get ticks() { return this.x.arc_ticks(this.handle); }
  get seconds() { return this.ticks / this.mod.ticksPerSecond; }
  get frameCount() { return this.x.arc_frame_count(this.handle); }
  get pc() { return this.x.arc_pc(this.handle) >>> 0; }

  key(code, down) { this.mod.check(this.x.arc_key(this.handle, code, down ? 1 : 0)); }
  mouseMove(dx, dy) { this.mod.check(this.x.arc_mouse_move(this.handle, dx | 0, dy | 0)); }
  releaseKeys() { this.mod.check(this.x.arc_release_keys(this.handle)); }
  /**
   * Steers RISC OS's pointer to the host's, at (x, y) in frame pixels; while
   * RISC OS's pointer is off, (dx, dy) goes as counts instead. null stops.
   * @returns {boolean} whether the host's own pointer can be hidden there
   */
  followPointer(spot, dx = 0, dy = 0) {
    const on = spot ? 1 : 0;
    return this.mod.check(this.x.arc_follow_pointer(this.handle, on, spot?.x | 0, spot?.y | 0, dx | 0, dy | 0)) === 1;
  }

  insertFloppy(bytes, { drive = 0, writeProtected = false } = {}) {
    this.mod.withBytes(bytes, (p, n) => this.mod.check(this.x.arc_insert_floppy(this.handle, drive, p, n, writeProtected ? 1 : 0)));
  }
  ejectFloppy(drive = 0) { this.mod.check(this.x.arc_eject_floppy(this.handle, drive)); }
  floppyContents(drive = 0) { return this.mod.result(this.mod.check(this.x.arc_floppy_contents(this.handle, drive))); }

  /**
   * Starts a Classic as the app does: its classics.json entry and floppies.
   * @param {object} game
   * @param {Uint8Array[]} discs
   */
  startClassic(game, discs) {
    const json = encoder.encode(JSON.stringify(game));
    const total = discs.reduce((n, d) => n + 4 + d.length, 0);
    const packed = new Uint8Array(total);
    const dv = new DataView(packed.buffer);
    let p = 0;
    for (const d of discs) { dv.setUint32(p, d.length, true); packed.set(d, p + 4); p += 4 + d.length; }
    this.mod.withBytes(json, (jp, jl) => this.mod.withBytes(packed, (dp, dl) =>
      this.mod.check(this.x.arc_start_classic(this.handle, jp, jl, dp, dl))));
  }
  get classicStarted() { return this.mod.check(this.x.arc_classic_started(this.handle)) === 1; }

  /**
   * The latest frame, if it's changed since the last call.
   * @param {boolean} [force] return it even if unchanged
   * @returns {{ width: number, height: number, scaleX: number, scaleY: number, number: number, rgba: Uint8ClampedArray } | null}
   */
  frame(force = false) {
    const changed = this.mod.check(this.x.arc_frame_update(this.handle)) === 1;
    if (!changed && !force) return null;
    const width = this.x.arc_frame_width(this.handle), height = this.x.arc_frame_height(this.handle);
    const ptr = this.x.arc_frame_ptr(this.handle);
    return {
      width, height,
      scaleX: this.x.arc_frame_scale_x(this.handle), scaleY: this.x.arc_frame_scale_y(this.handle),
      number: this.x.arc_frame_number(this.handle),
      rgba: new Uint8ClampedArray(this.x.memory.buffer, ptr, width * height * 4).slice(),
    };
  }

  /** The latest frame's checksum, as the native CLI prints it. */
  frameChecksum() { return decoder.decode(this.mod.result(this.mod.check(this.x.arc_frame_checksum(this.handle)))); }

  setAudioRate(rate) { this.mod.check(this.x.arc_audio_rate(this.handle, rate | 0)); }
  /** Interleaved stereo samples since the last call. */
  takeAudio() {
    const n = this.mod.check(this.x.arc_audio_take(this.handle));
    return n === 0 ? new Float32Array(0) : new Float32Array(this.x.memory.buffer, this.x.arc_audio_ptr(), n).slice();
  }

  readMemory(address, length, { logical = true } = {}) {
    return this.mod.result(this.mod.check(this.x.arc_read_memory(this.handle, address | 0, length, logical ? 1 : 0)));
  }
  saveState() { return this.mod.result(this.mod.check(this.x.arc_save_state(this.handle))); }
  restoreState(bytes) { this.mod.withBytes(bytes, (p, n) => this.mod.check(this.x.arc_restore_state(this.handle, p, n))); }
  recentText() { return decoder.decode(this.mod.result(this.mod.check(this.x.arc_recent_text(this.handle)))); }
  romVersion() { return decoder.decode(this.mod.result(this.mod.check(this.x.arc_rom_version(this.handle)))); }
}
