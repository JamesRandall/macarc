// Headless smoke: boots the real core (WASM) in Node and launches Zarch.
//   node web/tests/node-smoke.mjs <module.wasm> <rom> <disc.adf> [seconds] [out.bmp]
import fs from 'node:fs';
import path from 'node:path';
import { ArcModule } from '../src/arc-wasm.js';
import { writeBMP } from './bmp.mjs';

const [wasmPath, romPath, discPath, secondsArg, outPath] = process.argv.slice(2);
const seconds = Number(secondsArg ?? 60);
const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const catalogue = JSON.parse(fs.readFileSync(path.join(repo, 'Apps/MacArch/Resources/Classics/classics.json'), 'utf8'));
const zarch = catalogue.games.find((g) => g.id === 'zarch');

let t = performance.now();
const mod = await ArcModule.load(fs.readFileSync(wasmPath));
console.log(`instantiate ${(performance.now() - t).toFixed(0)} ms`);
t = performance.now();
const m = mod.createMachine({ rom: fs.readFileSync(romPath), model: zarch.machine.model, ramKB: zarch.machine.ramKB });
console.log(`create ${(performance.now() - t).toFixed(0)} ms, ROM ${m.romVersion()}`);
m.startClassic(zarch, [new Uint8Array(fs.readFileSync(discPath))]);

const tps = mod.ticksPerSecond, slice = tps / 50;
t = performance.now();
for (let s = 1; s <= seconds; s++) {
  for (let i = 0; i < 50; i++) m.run(slice);
  if (s % 10 === 0) console.log(`guest ${s}s  frame ${m.frameCount}  checksum ${m.frameChecksum()}  started ${m.classicStarted}  pc ${m.pc.toString(16)}`);
}
const wall = (performance.now() - t) / 1000;
console.log(`ran ${seconds} guest s in ${wall.toFixed(2)} s wall (${(seconds / wall).toFixed(2)}x real time)`);
if (outPath) {
  const f = m.frame(true);
  writeBMP(outPath, f);
  console.log(`frame ${f.width}x${f.height} -> ${outPath}`);
}
