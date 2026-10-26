// The page: controls, input and display. Emulation runs in arc-worker.js;
// this thread only forwards input and shows what the worker reports.

import { ARC_KEYS, ARC_BUTTONS } from './keymap.js';

const $ = (id) => document.getElementById(id);
const screen = $('screen');
const status = $('status');
const startButton = $('start');

const MAX_FILE_BYTES = 32 << 20;
const WASM_URL = new URL('../public/archimedes.wasm', import.meta.url).href;
const BUNDLE_URL = new URL('../public/bundled/manifest.json', import.meta.url).href;

let gen = 0;
let haveMachine = false;
let running = false;
let captured = false;
let held = new Set();
let savedState = null;
let bundle = null; // { rom, classic?: { game, discs } } from the bundled manifest
let romOverride = null;
let audio = null;
let pausedForHide = false;
const startup = {};

// Pixels of the frame, and the monitor's aspect (scaleX/scaleY), set the shape.
function setGeometry({ width, height, scaleX, scaleY }) {
  screen.style.aspectRatio = `${width * scaleX} / ${height * scaleY}`;
}

const worker = new Worker(new URL('./arc-worker.js', import.meta.url), { type: 'module' });
const offscreen = screen.transferControlToOffscreen();
const send = (msg, transfer = []) => worker.postMessage(msg, transfer);
send({ type: 'init', canvas: offscreen, wasmURL: WASM_URL }, [offscreen]);

function setStatus(text, error = false) {
  status.textContent = text;
  status.classList.toggle('error', error);
}

worker.onmessage = (e) => {
  const m = e.data;
  switch (m.type) {
    case 'loaded':
      startup.fetchMs = m.fetchMs; startup.instantiateMs = m.instantiateMs;
      $('s-wasm').textContent = `${(m.wasmBytes / 1048576).toFixed(1)} MB, fetched in ${m.fetchMs.toFixed(0)} ms, instantiated in ${m.instantiateMs.toFixed(0)} ms`;
      prepareStart();
      break;
    case 'machine':
      gen = m.gen;
      haveMachine = true;
      startup.createMs = m.createMs;
      $('s-startup').textContent = `fetch ${startup.fetchMs.toFixed(0)} ms · instantiate ${startup.instantiateMs.toFixed(0)} ms · create machine ${m.createMs.toFixed(0)} ms`;
      setStatus(`${m.model} · ${m.rom}`);
      for (const id of ['power', 'reset', 'pause', 'eject', 'save']) $(id).disabled = false;
      break;
    case 'state':
      running = m.running;
      $('pause').textContent = running ? 'Pause' : 'Resume';
      break;
    case 'geometry': setGeometry(m); break;
    case 'stats': showStats(m); break;
    case 'savedState':
      savedState = m.state;
      $('restore').disabled = false;
      setStatus(`Saved state (${(savedState.length / 1024).toFixed(0)} KB) at ${new Date().toLocaleTimeString()}`);
      break;
    case 'restored': setStatus('State loaded'); break;
    case 'inserted': setStatus(`Disc in drive ${m.drive}`); break;
    case 'error': setStatus(m.message, true); break;
  }
};
worker.onerror = (e) => setStatus(`Worker failed: ${e.message}`, true);

function showStats(s) {
  $('s-speed').textContent = `${(s.speed * 100).toFixed(0)}% of real time`;
  $('s-fps').textContent = `${s.fps.toFixed(1)} a second (frame ${s.frame})`;
  $('s-batch').textContent = `${s.runMedianMs.toFixed(2)} / ${s.runP95Ms.toFixed(2)} ms over ${s.batches} batches`;
  $('s-guest').textContent = `${s.guestSeconds.toFixed(1)} s${s.classicStarted ? ' · game started' : ''}`;
  $('s-ticks').textContent = `${s.requested.toLocaleString()} / ${s.executed.toLocaleString()} in the last ½ s`;
  $('s-mem').textContent = `${(s.memoryBytes / 1048576).toFixed(1)} MB`;
}

// MARK: Starting

async function fetchBytes(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

/** The bundled ROM and game, if the page was built with them (scripts/bundle-web.sh). */
async function loadBundle() {
  const r = await fetch(BUNDLE_URL);
  if (!r.ok) return null;
  const manifest = await r.json();
  const base = new URL('.', BUNDLE_URL);
  const rom = await fetchBytes(new URL(manifest.rom, base));
  let classic = null;
  if (manifest.classic) {
    const catalogue = await (await fetch(new URL(manifest.classic.catalogue, base))).json();
    const game = catalogue.games.find((g) => g.id === manifest.classic.id);
    if (!game) throw new Error(`no game ${manifest.classic.id} in the catalogue`);
    const discs = await Promise.all(manifest.classic.discs.map((d) => fetchBytes(new URL(d, base))));
    classic = { game, discs };
  }
  return { rom, classic };
}

async function prepareStart() {
  try {
    bundle = await loadBundle();
  } catch (e) {
    setStatus(`Bundled files: ${e.message}`, true);
  }
  if (bundle?.classic) {
    $('start-title').textContent = `Play ${bundle.classic.game.title}`;
    $('start-detail').textContent = `${bundle.classic.game.publisher}, ${bundle.classic.game.year} · ${bundle.classic.game.machine.summary}`;
    setStatus('Ready');
  } else if (bundle) {
    $('start-title').textContent = 'Switch on';
    $('start-detail').textContent = 'Boots the bundled ROM';
    setStatus('Ready');
  } else {
    $('start-title').textContent = 'Choose a RISC OS ROM';
    $('start-detail').textContent = 'A single 2 MB image (RISC OS 3 for most games). It stays in this tab.';
    setStatus('No ROM bundled with this page');
  }
  startButton.hidden = false;
  startButton.focus();
}

async function startAudio() {
  if (audio) { audio.ctx.resume(); return; }
  try {
    const ctx = new AudioContext({ latencyHint: 'interactive' });
    await ctx.audioWorklet.addModule(new URL('./audio-worklet.js', import.meta.url));
    const node = new AudioWorkletNode(ctx, 'arc-audio', { outputChannelCount: [2] });
    node.connect(ctx.destination);
    audio = { ctx, node };
    // The worker sends samples to the worklet directly, not through here.
    send({ type: 'audio', port: node.port, rate: ctx.sampleRate }, [node.port]);
  } catch (e) {
    console.warn('No audio:', e);
  }
}

function boot() {
  const rom = romOverride ?? bundle?.rom;
  if (!rom) { $('rom-file').click(); return; }
  const config = { rom, model: 'A3000' };
  if (!romOverride && bundle?.classic) {
    config.model = bundle.classic.game.machine.model;
    config.ramKB = bundle.classic.game.machine.ramKB;
    config.classic = bundle.classic;
  }
  setStatus('Switching on…');
  send({ type: 'build', config });
}

startButton.addEventListener('click', async () => {
  if (!romOverride && !bundle) { $('rom-file').click(); return; }
  startButton.hidden = true;
  await startAudio();
  boot();
});

// MARK: Controls

$('power').onclick = () => { releaseAll(); send({ type: 'power' }); };
$('reset').onclick = () => send({ type: 'reset' });
$('pause').onclick = () => send({ type: running ? 'pause' : 'resume' });
$('eject').onclick = () => send({ type: 'eject', drive: 0 });
$('save').onclick = () => send({ type: 'saveState' });
$('restore').onclick = () => { if (savedState) send({ type: 'restoreState', state: savedState.slice() }); };
$('debug').onchange = (e) => { $('stats').hidden = !e.target.checked; };

async function readFile(input) {
  const f = input.files?.[0];
  input.value = '';
  if (!f) return null;
  if (f.size > MAX_FILE_BYTES) { setStatus(`${f.name} is too big (${f.size} bytes)`, true); return null; }
  return { name: f.name, bytes: new Uint8Array(await f.arrayBuffer()) };
}

$('disc-file').onchange = async (e) => {
  const f = await readFile(e.target);
  if (!f) return;
  if (!haveMachine) { setStatus('Switch the machine on first', true); return; }
  send({ type: 'insert', drive: 0, bytes: f.bytes }, [f.bytes.buffer]);
};

$('rom-file').onchange = async (e) => {
  const f = await readFile(e.target);
  if (!f) return;
  romOverride = f.bytes;
  startButton.hidden = true;
  await startAudio();
  releaseAll();
  boot();
};

// MARK: Keyboard

function releaseAll() {
  for (const code of held) send({ type: 'key', gen, code, down: false });
  held.clear();
  if (haveMachine) send({ type: 'releaseKeys', gen });
}

function keyEvent(e, down) {
  if (!haveMachine || !running) return;
  if (e.metaKey) return; // leave the browser's own shortcuts alone
  const target = e.target;
  if (target instanceof HTMLInputElement || target instanceof HTMLSelectElement) return;
  const code = ARC_KEYS[e.code];
  if (code === undefined) return;
  e.preventDefault();
  if (down) {
    if (e.repeat || held.has(code)) return; // RISC OS does its own auto-repeat
    held.add(code);
  } else {
    if (!held.has(code)) return;
    held.delete(code);
  }
  send({ type: 'key', gen, code, down });
}

window.addEventListener('keydown', (e) => keyEvent(e, true));
window.addEventListener('keyup', (e) => keyEvent(e, false));
window.addEventListener('blur', releaseAll);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    releaseAll();
    if (running) { send({ type: 'pause' }); pausedForHide = true; }
  } else if (pausedForHide) {
    pausedForHide = false;
    send({ type: 'resume' });
  }
});

// MARK: Mouse

screen.addEventListener('mousedown', (e) => {
  if (!haveMachine) return;
  if (!captured) { screen.requestPointerLock(); return; }
  const code = ARC_BUTTONS[e.button];
  if (code === undefined) return;
  e.preventDefault();
  held.add(code);
  send({ type: 'key', gen, code, down: true });
});
window.addEventListener('mouseup', (e) => {
  const code = ARC_BUTTONS[e.button];
  if (code === undefined || !held.has(code)) return;
  held.delete(code);
  send({ type: 'key', gen, code, down: false });
});
screen.addEventListener('contextmenu', (e) => e.preventDefault());

// Mouse counts are coalesced into one message per animation frame.
let mdx = 0, mdy = 0, mousePending = false;
document.addEventListener('mousemove', (e) => {
  if (!captured) return;
  mdx += e.movementX;
  mdy -= e.movementY; // the Archimedes mouse counts up as it moves away
  if (!mousePending) {
    mousePending = true;
    requestAnimationFrame(() => {
      mousePending = false;
      if (mdx || mdy) send({ type: 'mouse', gen, dx: mdx, dy: mdy });
      mdx = 0; mdy = 0;
    });
  }
});

document.addEventListener('pointerlockchange', () => {
  captured = document.pointerLockElement === screen;
  screen.classList.toggle('captured', captured);
  if (!captured) {
    // Buttons held when the mouse was let go would stick.
    for (const code of Object.values(ARC_BUTTONS)) {
      if (held.delete(code)) send({ type: 'key', gen, code, down: false });
    }
  }
});
