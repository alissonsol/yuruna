// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const fixture = JSON.parse(fs.readFileSync(path.join(root, 'globalization/fixtures/pt-BR-plurals.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'globalization/locale-manifest.json'), 'utf8'));
const data = {};
for (const [tag, row] of Object.entries(manifest.locales)) data[tag] = { plural: row.pluralRule, direction: row.direction };
const window = { YurunaLocaleData: data };
vm.runInNewContext(fs.readFileSync(path.join(root, 'globalization/kernel/yuruna.i18n.js'), 'utf8'), { window });
for (const row of fixture.cases) assert.equal(window.YurunaI18n.pluralCategory(fixture.locale, row.count), row.category, 'count=' + row.count);
console.log('Portuguese browser plural corpus: ' + fixture.cases.length + ' cases passed');
