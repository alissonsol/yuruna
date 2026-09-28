// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function checkUpload(formId) {
  const elements = {};
  const calls = [];
  function element(id) {
    if (!elements[id]) elements[id] = {
      className: '', style: {}, value: 'text', files: [{}], handlers: {}, disabled: false,
      setAttribute() {}, addEventListener(name, fn) { this.handlers[name] = fn; },
      querySelector() { return element(id + '-button'); }
    };
    return elements[id];
  }
  let complete;
  const pending = new Promise(resolve => { complete = resolve; });
  const box = {
    document: { getElementById: element },
    FormData: class { constructor(form) { this.form = form; } },
    Y: { api(url, options) { calls.push({url, options}); return pending; }, initFooter() {} },
    location: { href: '' },
    YurunaFirstUsable: { measure(_page, _mode, fn) { return fn(); }, mark() {} },
    YurunaI18n: { t(key) { return key; } }
  };
  box.window = box;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'new.js'), 'utf8'), box);
  const button = element(formId + '-button');
  element(formId).handlers.submit({ preventDefault() {}, submitter: button });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/stashes');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.body.form, element(formId));
  assert.ok(calls[0].options.timeoutMs >= 60 * 60 * 1000, 'uploads must outlive the ordinary 10-second API budget');
  assert.equal(button.disabled, true);
  assert.equal(box.location.href, '');
  complete({permalink: '/s/finished'});
  await pending;
  await Promise.resolve();
  assert.equal(box.location.href, '/s/finished');
}
(async () => {
  await checkUpload('form-files');
  await checkUpload('form-text');
  console.log('PASS: stash uploads use the transfer timeout and wait for completion');
})().catch(error => { console.error(error); process.exitCode = 1; });
