// End-to-end in a real browser (system Chrome, headless, via playwright-core):
// fresh load, switch on with the bundled ROM and game, watch the game start,
// press a key, pause/resume, reset and power-cycle. Screenshots go to
// web/tests/out/. Needs the page served (npm run serve) and a bundle
// (scripts/bundle-web.sh).
//   node tests/browser-smoke.mjs [url]

import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright-core';

const url = process.argv[2] ?? 'http://localhost:8080/';
const out = path.join(path.dirname(new URL(import.meta.url).pathname), 'out');
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: 1100, height: 1000 } });
const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`); });

const step = (s) => console.log(`- ${s}`);
const stat = (id) => page.locator(`#${id}`).textContent();
const guestSeconds = async () => parseFloat(await stat('s-guest'));
const shot = (name) => page.locator('#bezel').screenshot({ path: path.join(out, `${name}.png`) });
function check(ok, message) { if (!ok) throw new Error(message); }

try {
  const t0 = Date.now();
  await page.goto(url);
  await page.locator('#start:not([hidden])').waitFor({ timeout: 60_000 });
  step(`page and module ready in ${Date.now() - t0} ms: "${await page.locator('#start-title').textContent()}"`);
  await page.locator('#debug').check();

  await page.locator('#start').click();
  check(await page.locator('#start').isHidden(), 'the start button is still showing');
  await page.waitForFunction(() => /RISC OS/.test(document.getElementById('status').textContent), null, { timeout: 30_000 });
  step(`switched on: ${await stat('status')}`);

  // RISC OS boots to the desktop, then the launcher types the game's start.
  await page.waitForFunction(() => /game started/.test(document.getElementById('s-guest').textContent), null, { timeout: 120_000 });
  step(`game started at guest ${await guestSeconds()} s`);
  await page.waitForTimeout(16_000);
  await shot('1-zarch-title');
  step(`speed ${await stat('s-speed')}, frames ${await stat('s-fps')}, batches ${await stat('s-batch')}, memory ${await stat('s-mem')}`);
  check(parseFloat(await stat('s-speed')) >= 90, `emulation too slow: ${await stat('s-speed')}`);

  // "Press a key to continue": Space, held briefly.
  await page.keyboard.down('Space');
  await page.waitForTimeout(150);
  await page.keyboard.up('Space');
  await page.waitForTimeout(8_000);
  await shot('2-after-key');
  step('pressed Space');

  await page.locator('#pause').click();
  await page.waitForTimeout(600);
  const pausedAt = await guestSeconds();
  await page.waitForTimeout(1_500);
  check(await guestSeconds() === pausedAt, 'guest time moved while paused');
  await page.locator('#pause').click();
  await page.waitForTimeout(1_500);
  check(await guestSeconds() > pausedAt, 'guest time did not resume');
  step(`pause held guest time at ${pausedAt} s; resume continued it`);

  // Keys held when the window loses focus are let go.
  await page.keyboard.down('KeyA');
  await page.evaluate(() => window.dispatchEvent(new Event('blur')));
  await page.keyboard.up('KeyA');
  step('released held keys on blur');

  await page.locator('#save').click();
  await page.waitForFunction(() => /Saved state/.test(document.getElementById('status').textContent));
  step(await stat('status'));
  await page.locator('#restore').click();
  await page.waitForFunction(() => /State loaded/.test(document.getElementById('status').textContent));
  step('state loaded');

  await page.locator('#reset').click();
  await page.waitForTimeout(3_000);
  await shot('3-after-reset');
  step('reset');

  await page.locator('#power').click();
  await page.waitForTimeout(1_000);
  const afterPower = await guestSeconds();
  check(afterPower < 3, `power cycle didn't restart guest time (${afterPower} s)`);
  step(`power cycled (guest ${afterPower} s)`);

  check(errors.length === 0, `errors in the page:\n${errors.join('\n')}`);
  console.log(`PASS (screenshots in ${out})`);
} catch (e) {
  await page.screenshot({ path: path.join(out, 'failure.png') }).catch(() => {});
  console.error(`FAIL: ${e.message}`);
  if (errors.length) console.error(errors.join('\n'));
  process.exitCode = 1;
} finally {
  await browser.close();
}
