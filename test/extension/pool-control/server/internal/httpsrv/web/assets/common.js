// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Shared, XSS-safe helpers for the Pool control UI. No innerHTML on data.
(function () {
  const Y = {};
  Y.el = function (tag, attrs, children) {
    const e = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k === 'class') e.className = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    if (children) for (const c of [].concat(children)) {
      if (c === null || c === undefined) continue;
      e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
  };
  Y.api = async function (path, opts) {
    opts = opts || {};
    const res = await fetch(path, {
      method: opts.method || 'GET',
      headers: opts.body ? { 'Content-Type': 'application/json' } : {},
      body: opts.body ? JSON.stringify(opts.body) : undefined
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* non-JSON */ }
    if (!res.ok || data.ok === false) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  };
  Y.notice = function (kind, msg) {
    const n = document.getElementById('notice');
    if (!n) return;
    n.className = 'notice ' + kind;
    n.textContent = msg;
    n.style.display = 'block';
  };
  Y.clearNotice = function () {
    const n = document.getElementById('notice');
    if (n) { n.style.display = 'none'; n.textContent = ''; }
  };
  window.Y = Y;
})();
