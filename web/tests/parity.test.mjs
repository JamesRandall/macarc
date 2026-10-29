// The WASM module against the fixtures the native tests also assert
// (Packages/ArchimedesCore/Tests/Fixtures/wasm-parity.json), plus the ABI's
// error handling and lifetimes. Run: npm test (after scripts/build-wasm.sh).
//
// ARC_WASM overrides the module path; MACARCH_TEST_ROM / MACARCH_TEST_ZARCH
// point at the licensed local fixtures (that test is skipped without them).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ArcModule, ArcError } from '../src/arc-wasm.js';

const here = path.dirname(new URL(import.meta.url).pathname);
const repo = path.resolve(here, '../..');
const wasmPath = process.env.ARC_WASM ?? path.join(repo, 'web/public/archimedes.wasm');
const fixtures = JSON.parse(fs.readFileSync(path.join(repo, 'Packages/ArchimedesCore/Tests/Fixtures/wasm-parity.json'), 'utf8'));
const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');

const mod = await ArcModule.load(fs.readFileSync(wasmPath), { log: () => {} });

function syntheticROM() {
  const f = fixtures.synthetic;
  const rom = new Uint8Array(f.romBytes);
  const dv = new DataView(rom.buffer);
  f.romWords.forEach((w, i) => dv.setUint32(i * 4, w, true));
  return rom;
}

test('synthetic ROM run matches the native fixture', () => {
  const f = fixtures.synthetic;
  const m = mod.createMachine({ rom: syntheticROM(), cmosReset: false });
  for (let i = 0; i < f.slices; i++) m.run(f.sliceTicks);
  assert.equal(m.ticks, f.ticks);
  assert.equal(m.pc, f.pc);
  assert.equal(sha256(m.readMemory(0x02000000, 65536)), f.ramSHA256);
  m.release();
});

test('snapshot restores into a fresh machine and continues identically', () => {
  const rom = syntheticROM();
  const a = mod.createMachine({ rom, cmosReset: false });
  a.run(1_000_000);
  const state = a.saveState();
  const b = mod.createMachine({ rom, cmosReset: false });
  b.restoreState(state);
  assert.equal(a.ticks, b.ticks);
  a.run(500_000); b.run(500_000);
  assert.equal(a.ticks, b.ticks);
  assert.deepEqual(a.readMemory(0x02000000, 65536), b.readMemory(0x02000000, 65536));
  a.release(); b.release();
});

test('invalid inputs fail with error codes, not traps', () => {
  const rom = syntheticROM();
  assert.throws(() => mod.createMachine({ rom, model: 'BBC Micro' }), (e) => e instanceof ArcError && e.code === -4);
  assert.throws(() => mod.createMachine({ rom: new Uint8Array([1, 2, 3]) }), (e) => e instanceof ArcError && e.code === -3);
  const m = mod.createMachine({ rom, cmosReset: false });
  assert.throws(() => m.insertFloppy(new Uint8Array(3)), (e) => e.code === -5);
  assert.throws(() => m.insertFloppy(new Uint8Array(819200), { drive: 9 }), (e) => e.code === -2);
  assert.throws(() => m.key(0x200, true), (e) => e.code === -2);
  assert.throws(() => m.run(-1), (e) => e.code === -2);
  assert.throws(() => m.restoreState(new Uint8Array([0, 1, 2, 3])), (e) => e.code === -6);
  assert.throws(() => m.restoreState(m.saveState().slice(0, 100)), (e) => e.code === -6);
  assert.throws(() => m.readMemory(0, 2 << 20), (e) => e.code === -2);
  assert.throws(() => m.startClassic({}, []), (e) => e.code === -2);
  m.run(24_000); // still fine
  const h = m.handle;
  m.release();
  assert.throws(() => m.release(), (e) => e.code === -1);
  assert.equal(mod.x.arc_run(h, 1000), -1);
  assert.equal(mod.x.arc_run(12345, 1000), -1);
});

test('machines are independent, and creating and releasing them does not grow memory', () => {
  const rom = syntheticROM();
  const a = mod.createMachine({ rom, cmosReset: false });
  const b = mod.createMachine({ rom, model: 'A5000', cmosReset: false });
  a.run(480_000);
  assert.equal(b.ticks, 0);
  b.run(480_000);
  a.release(); b.release();
  for (let i = 0; i < 5; i++) { const m = mod.createMachine({ rom, cmosReset: false }); m.run(48_000); m.saveState(); m.release(); }
  const settled = mod.memory.buffer.byteLength;
  for (let i = 0; i < 20; i++) { const m = mod.createMachine({ rom, cmosReset: false }); m.run(48_000); m.saveState(); m.release(); }
  assert.equal(mod.memory.buffer.byteLength, settled);
  assert.equal(mod.machineCount, 0);
});

const romPath = process.env.MACARCH_TEST_ROM ?? path.join(repo, 'roms/arclibre.rom');
const zarchPath = process.env.MACARCH_TEST_ZARCH ?? path.join(os.homedir(), 'code/macarc/top25/Zarch (1987)(Superior Software).adf');
const haveZarch = fs.existsSync(romPath) && fs.existsSync(zarchPath);

test('Zarch launches with the same frames as native', { skip: !haveZarch && 'needs a RISC OS ROM and the Zarch disc' }, () => {
  const f = fixtures.zarch;
  const rom = fs.readFileSync(romPath), disc = fs.readFileSync(zarchPath);
  assert.equal(sha256(rom), f.romSHA256);
  assert.equal(sha256(disc), f.discSHA256);
  const catalogue = JSON.parse(fs.readFileSync(path.join(repo, 'Apps/MacArch/Resources/Classics/classics.json'), 'utf8'));
  const m = mod.createMachine({ rom, model: 'A3000' });
  m.startClassic(catalogue.games.find((g) => g.id === 'zarch'), [new Uint8Array(disc)]);
  let second = 0;
  for (const c of f.checkpoints) {
    while (second < c.seconds) { for (let i = 0; i < mod.ticksPerSecond / f.sliceTicks; i++) m.run(f.sliceTicks); second++; }
    assert.equal(m.frameCount, c.frame, `frame at ${c.seconds} s`);
    assert.equal(m.frameChecksum(), c.checksum, `checksum at ${c.seconds} s`);
  }
  assert.ok(m.classicStarted);
  m.release();
});
