// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const fixtureRoot = path.join(root, 'globalization/fixtures');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'globalization/locale-manifest.json'), 'utf8'));
const data = {};
for (const [tag, row] of Object.entries(manifest.locales)) data[tag] = { plural: row.pluralRule, direction: row.direction };
// The kernel reports an unknown rule through console.warn and answers
// other, which is also every zh-CN answer; the warning is the only sign that
// a rule is missing, so it fails the run.
const warnings = [];
const window = { YurunaLocaleData: data, console: { warn: (message) => { warnings.push(String(message)); } } };
vm.runInNewContext(fs.readFileSync(path.join(root, 'globalization/kernel/yuruna.i18n.js'), 'utf8'), { window });
// Every pinned corpus, so a new locale's fixture is held to the kernel the
// moment it exists.
const names = fs.readdirSync(fixtureRoot).filter((name) => name.endsWith('-plurals.json')).sort();
assert.ok(names.length >= 3, 'found ' + names.length + ' plural corpora');
for (const name of names) {
  const fixture = JSON.parse(fs.readFileSync(path.join(fixtureRoot, name), 'utf8'));
  for (const row of fixture.cases) {
    assert.equal(window.YurunaI18n.pluralCategory(fixture.locale, row.count), row.category, fixture.locale + ' count=' + row.count);
  }
  console.log(fixture.locale + ' browser plural corpus: ' + fixture.cases.length + ' cases passed');
}
assert.deepEqual(warnings, [], 'the kernel reported: ' + warnings.join('; '));
