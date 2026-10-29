// The emulation worker: owns the WebAssembly module and the machine, paces
// guest time against the browser's monotonic clock, draws frames into the
// OffscreenCanvas it's given, and sends sound to the audio worklet's port.
// The page only sends it messages (input, controls) and shows what it says.
//
// Messages carry a `gen`: the machine generation they're for. Anything for
// an older machine (one replaced by a power cycle or a state load) is
// ignored, so input can't leak across.

import { ArcModule } from './arc-wasm.js';

const MAX_CATCH_UP_MS = 100; // longer stalls (a hidden tab, a debugger) are dropped, not replayed
const TICK_MS = 4;

let mod = null;
let machine = null;
let gen = 0;
let canvas = null, ctx = null;
let audioPort = null, audioRate = 0;
let running = false;
let timer = 0;
let lastWall = 0;
let owedTicks = 0;
let speed = 1;
let pointerHidden = false; // last told to the page (followPointer)
let config = null;
let wasmBytes = 0;
const stats = { frames: 0, requestedTicks: 0, executedTicks: 0, runMs: [], lastReport: 0 };

const post = (type, data = {}, transfer = []) => postMessage({ type, gen, ...data }, transfer);

function fail(where, e) {
  console.error(where, e);
  post('error', { message: `${where}: ${e.message ?? e}` });
}

async function loadModule(url) {
  const t0 = performance.now();
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  const bytes = await response.arrayBuffer();
  wasmBytes = bytes.byteLength;
  const t1 = performance.now();
  mod = await ArcModule.load(bytes, { log: (s) => console.log('[wasm]', s) });
  const t2 = performance.now();
  post('loaded', { wasmBytes, fetchMs: t1 - t0, instantiateMs: t2 - t1 });
}

/** A new machine from `c`: { rom, model, ramKB, classic?: { game, discs }, discs?: [{ drive, bytes }] }. */
function build(c) {
  pointerHidden = false;
  stop();
  if (machine) { machine.release(); machine = null; }
  gen++;
  const t0 = performance.now();
  machine = mod.createMachine({ rom: c.rom, model: c.model ?? 'A3000', ramKB: c.ramKB ?? 0, cmosReset: true });
  if (c.classic) machine.startClassic(c.classic.game, c.classic.discs);
  for (const d of c.discs ?? []) machine.insertFloppy(d.bytes, { drive: d.drive ?? 0 });
  if (audioRate) machine.setAudioRate(audioRate);
  audioPort?.postMessage('clear');
  config = c;
  post('machine', { rom: machine.romVersion(), model: c.model ?? 'A3000', createMs: performance.now() - t0 });
  start();
}

function start() {
  if (!machine || running) return;
  running = true;
  lastWall = performance.now();
  owedTicks = 0;
  timer = setInterval(tick, TICK_MS);
  post('state', { running });
}

function stop() {
  if (!running) return;
  running = false;
  clearInterval(timer);
  post('state', { running });
}

function tick() {
  const now = performance.now();
  const elapsed = Math.min(now - lastWall, MAX_CATCH_UP_MS);
  lastWall = now;
  const tps = mod.ticksPerSecond;
  owedTicks += elapsed * tps / 1000 * speed;
  // Whole milliseconds of guest time at a time.
  const quantum = tps / 1000;
  const n = Math.floor(owedTicks / quantum) * quantum;
  if (n <= 0) return;
  owedTicks -= n;
  const before = machine.ticks;
  const t0 = performance.now();
  try {
    machine.run(n);
  } catch (e) {
    stop();
    fail('run', e);
    return;
  }
  const t1 = performance.now();
  stats.requestedTicks += n;
  stats.executedTicks += machine.ticks - before;
  stats.runMs.push(t1 - t0);
  present();
  if (audioPort && audioRate) {
    const s = machine.takeAudio();
    if (s.length) audioPort.postMessage(s, [s.buffer]);
  }
  if (now - stats.lastReport >= 500) report(now);
}

function present() {
  const f = machine.frame();
  if (!f || !ctx) return;
  stats.frames++;
  if (canvas.width !== f.width || canvas.height !== f.height) {
    canvas.width = f.width;
    canvas.height = f.height;
    post('geometry', { width: f.width, height: f.height, scaleX: f.scaleX, scaleY: f.scaleY });
  }
  ctx.putImageData(new ImageData(f.rgba, f.width, f.height), 0, 0);
}

function report(now) {
  const span = (now - stats.lastReport) / 1000;
  const sorted = stats.runMs.slice().sort((a, b) => a - b);
  const pct = (p) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : 0;
  post('stats', {
    fps: stats.frames / span,
    speed: stats.executedTicks / mod.ticksPerSecond / span,
    requested: stats.requestedTicks,
    executed: stats.executedTicks,
    runMedianMs: pct(0.5),
    runP95Ms: pct(0.95),
    batches: sorted.length,
    guestSeconds: machine.seconds,
    frame: machine.frameCount,
    classicStarted: machine.classicStarted,
    wasmBytes,
    memoryBytes: mod.memory.buffer.byteLength,
  });
  stats.frames = 0; stats.requestedTicks = 0; stats.executedTicks = 0; stats.runMs = [];
  stats.lastReport = now;
}

onmessage = async (e) => {
  const m = e.data;
  // Input for a machine that's since been replaced is dropped.
  if (m.gen !== undefined && m.gen !== gen) return;
  try {
    switch (m.type) {
      case 'init':
        canvas = m.canvas;
        ctx = canvas.getContext('2d', { alpha: false });
        await loadModule(m.wasmURL);
        break;
      case 'audio':
        audioPort = m.port;
        audioRate = m.rate;
        machine?.setAudioRate(audioRate);
        break;
      case 'build': build(m.config); break;
      case 'power': if (config) build(config); break;
      case 'reset': machine?.reset(); break;
      case 'pause': stop(); break;
      case 'resume': start(); break;
      case 'speed': speed = m.speed; break;
      case 'key': machine?.key(m.code, m.down); break;
      case 'mouse': machine?.mouseMove(m.dx, m.dy); break;
      case 'follow': {
        const hide = machine?.followPointer(m.spot, m.dx, m.dy) ?? false;
        if (hide !== pointerHidden) { pointerHidden = hide; post('pointer', { hide }); }
        break;
      }
      case 'releaseKeys': machine?.releaseKeys(); break;
      case 'insert':
        machine?.insertFloppy(m.bytes, { drive: m.drive ?? 0 });
        post('inserted', { drive: m.drive ?? 0 });
        break;
      case 'eject': machine?.ejectFloppy(m.drive ?? 0); break;
      case 'saveState': {
        const state = machine.saveState();
        post('savedState', { state }, [state.buffer]);
        break;
      }
      case 'restoreState': {
        machine.restoreState(m.state);
        audioPort?.postMessage('clear');
        // (Same machine object, new emulated state: frames come from it.)
        post('restored', {});
        break;
      }
    }
  } catch (err) {
    fail(m.type, err);
  }
};
