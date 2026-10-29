import fs from 'node:fs';

/** Writes an RGBA frame as a 24-bit BMP (for eyeballing headless runs). */
export function writeBMP(file, { width, height, rgba }) {
  const row = (width * 3 + 3) & ~3;
  const buf = Buffer.alloc(54 + row * height);
  buf.write('BM', 0); buf.writeUInt32LE(buf.length, 2); buf.writeUInt32LE(54, 10);
  buf.writeUInt32LE(40, 14); buf.writeInt32LE(width, 18); buf.writeInt32LE(-height, 22);
  buf.writeUInt16LE(1, 26); buf.writeUInt16LE(24, 28); buf.writeUInt32LE(row * height, 34);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4, d = 54 + y * row + x * 3;
      buf[d] = rgba[s + 2]; buf[d + 1] = rgba[s + 1]; buf[d + 2] = rgba[s];
    }
  }
  fs.writeFileSync(file, buf);
}
