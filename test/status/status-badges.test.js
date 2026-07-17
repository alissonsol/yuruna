/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.07.17

  Framework-free structural check for the per-row status badge colors. Run:
  node status-badges.test.js (exit 0 = pass). No repo JS test runner and no
  browser here, so this verifies the CSS promotion structurally, not visually:

    - the 7 status colors live in yuruna.common.css, scoped to .badge /
      .step-pill (the elements yuruna.common.js emits), with the status
      theme var() values;
    - index.html does not define the bare .pass/.fail/... status colors
      inline (they are not duplicated);
    - both files are brace-balanced.

  The .badge/.step-pill scope is deliberate: perf.html reuses bare status
  words for unrelated elements (.cycle-dur.fail), so an unscoped promotion
  would tint them. This check does NOT prove the rendered colors -- eyeball
  index / hostinfo / test.config / perf in a browser.
*/
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const css = fs.readFileSync(path.join(__dirname, 'yuruna.common.css'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');

// status -> the exact var() pair its rule sets (background, then color).
const STATUS = [
  { name: 'idle',    bg: '--bg-hover',   fg: '--fg-muted' },
  { name: 'pending', bg: '--bg-hover',   fg: '--fg-muted' },
  { name: 'running', bg: '--running-bg', fg: '--running-fg' },
  { name: 'pass',    bg: '--pass-bg',    fg: '--pass-fg' },
  { name: 'fail',    bg: '--fail-bg',    fg: '--fail-fg' },
  { name: 'skipped', bg: '--skipped-bg', fg: '--skipped-fg' },
  { name: 'paused',  bg: '--pending-bg', fg: '--pending-fg' }
];

function esc(s) { return s.replace(/[-]/g, '\\-'); }

for (const s of STATUS) {
  // The shared CSS must carry the rule scoped to .badge AND .step-pill, with the
  // status theme var() values.
  const re = new RegExp(
    '\\.badge\\.' + s.name + ',\\s*\\.step-pill\\.' + s.name +
    '[^{]*\\{[^}]*background:\\s*var\\(' + esc(s.bg) + '\\);[^}]*color:\\s*var\\(' + esc(s.fg) + '\\);[^}]*\\}'
  );
  assert.match(css, re, 'yuruna.common.css must define .badge.' + s.name + ' / .step-pill.' + s.name + ' with the status var() values');

  // index.html must not define the bare status color inline (kept in one place).
  const inlineRe = new RegExp('\\n\\s*\\.' + s.name + ',\\s*\\.' + s.name + '-bg\\s*\\{');
  assert.ok(!inlineRe.test(html), 'index.html must not define .' + s.name + ' inline');
}

// Both files must be brace-balanced (a crude parse sanity check).
for (const [label, text] of [['yuruna.common.css', css], ['index.html', html]]) {
  const open = (text.match(/\{/g) || []).length;
  const close = (text.match(/\}/g) || []).length;
  assert.strictEqual(open, close, label + ' braces must balance (' + open + ' open vs ' + close + ' close)');
}

console.log('PASS: status-badges -- ' + (STATUS.length * 2 + 2) + ' assertions');
