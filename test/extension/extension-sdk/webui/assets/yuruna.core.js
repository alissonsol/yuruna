// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The shared browser runtime for every Yuruna extension service UI: the page
// chrome (header, menu, footer, countdown), the JSON client, the table
// furniture and the small set of shims the baseline browser needs. A service
// loads this before its own common.js and adds only what is its own.
//
// ES5 ONLY, and deliberately so. The floor is Safari iOS 9.3 / Safari 9.1 (see
// the browser baseline in docs/definition.md), whose parser rejects a file
// carrying one arrow function OUTRIGHT -- not the statement, the file. A page
// whose runtime failed to parse still serves its static shell, so the failure
// looks like an empty table rather than like a broken page, and nothing in the
// browser says otherwise. tools/Invoke-Es5Check.ps1 is what holds this line;
// run it before shipping a change here.
//
// Untrusted data is placed with textContent and safe DOM APIs, never innerHTML.
(function (window, document) {
  'use strict';

  var Y = window.Y || {};
  window.Y = Y;

  var has = function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); };

  // --- shims ---------------------------------------------------------------
  // Each is feature-detected, so a current browser keeps its own native
  // implementation and only the floor build pays for the replacement.

  // fetch arrived in iOS 10.3. The XHR stand-in covers the surface these UIs
  // actually use -- status, ok, text(), json() -- and nothing else, because a
  // partial shim that is honest about its shape is easier to reason about than
  // one that pretends to be the whole API. Mirrors the status pages' shim.
  if (!window.fetch) {
    window.fetch = function (url, options) {
      options = options || {};
      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open(options.method || 'GET', url, true);
        var headers = options.headers;
        if (headers) {
          for (var k in headers) {
            if (has(headers, k)) { xhr.setRequestHeader(k, headers[k]); }
          }
        }
        xhr.onload = function () {
          var body = xhr.responseText;
          resolve({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            statusText: xhr.statusText,
            text: function () { return Promise.resolve(body); },
            json: function () {
              return new Promise(function (res, rej) {
                try { res(JSON.parse(body)); } catch (e) { rej(e); }
              });
            }
          });
        };
        xhr.onerror = function () { reject(new Error('Network error')); };
        // Carried so Y.api can abandon a stalled request; the native path uses
        // AbortController for the same job.
        if (options.yurunaXhrOut) { options.yurunaXhrOut(xhr); }
        xhr.send(options.body || null);
      });
    };
  }

  if (!Object.assign) {
    Object.assign = function (target) {
      for (var i = 1; i < arguments.length; i++) {
        var src = arguments[i];
        if (!src) { continue; }
        for (var k in src) { if (has(src, k)) { target[k] = src[k]; } }
      }
      return target;
    };
  }

  if (!Number.isFinite) {
    Number.isFinite = function (v) { return typeof v === 'number' && isFinite(v); };
  }

  if (window.Element && !Element.prototype.closest) {
    Element.prototype.closest = function (sel) {
      var node = this;
      var matches = node.matches || node.webkitMatchesSelector || node.msMatchesSelector;
      while (node && node.nodeType === 1) {
        if (matches && matches.call(node, sel)) { return node; }
        node = node.parentElement;
      }
      return null;
    };
  }

  // KeyboardEvent.key landed in iOS 10.3, so every comparison against it needs
  // somewhere to fall back to. Only the keys this UI acts on are mapped: a
  // dialog's Escape, a menu's Escape, a select's Enter and arrows. Anything
  // else comes back as the raw .key or ''.
  var KEY_BY_CODE = {
    9: 'Tab', 13: 'Enter', 27: 'Escape', 32: ' ',
    33: 'PageUp', 34: 'PageDown', 35: 'End', 36: 'Home',
    37: 'ArrowLeft', 38: 'ArrowUp', 39: 'ArrowRight', 40: 'ArrowDown'
  };
  Y.key = function (ev) {
    if (!ev) { return ''; }
    if (typeof ev.key === 'string' && ev.key !== '') {
      // The floor build's near-miss spellings, from the pre-standard draft.
      if (ev.key === 'Esc') { return 'Escape'; }
      if (ev.key === 'Left') { return 'ArrowLeft'; }
      if (ev.key === 'Right') { return 'ArrowRight'; }
      if (ev.key === 'Up') { return 'ArrowUp'; }
      if (ev.key === 'Down') { return 'ArrowDown'; }
      return ev.key;
    }
    var code = ev.keyCode || ev.which || 0;
    return KEY_BY_CODE[code] || '';
  };

  // --- DOM building --------------------------------------------------------

  // safeUrl gates href/src attribute values: only same-origin relative paths
  // and absolute http(s) URLs are allowed, so a javascript:/data:/vbscript:
  // value can never become an executable link. Returns null to drop the
  // attribute entirely.
  //
  // extraSchemes widens it for a caller that has already established what a
  // value is. `file:` is the case in practice -- a host whose repository is a
  // local clone, an image pool folder on a share -- and it is deliberately NOT
  // in the default set: Y.el applies this to every href it builds, and a link
  // that is only meaningful to whoever is sitting at that machine should be
  // opted into by the one page that means it, not granted to all of them.
  //
  // Parsed with an anchor element rather than `new URL`, which the floor build
  // does not carry. Assigning to a detached anchor's href resolves it against
  // the document exactly as the URL constructor would, and reading .protocol
  // back gives the scheme the browser itself would follow.
  Y.safeUrl = function (v, extraSchemes) {
    var s = String(v === null || v === undefined ? '' : v);
    s = s.replace(/^\s+|\s+$/g, '');
    if (s === '') { return null; }
    if (s.charAt(0) === '/' && s.charAt(1) !== '/') { return s; }
    try {
      var a = document.createElement('a');
      a.href = s;
      if (a.protocol === 'http:' || a.protocol === 'https:') { return s; }
      if (extraSchemes && extraSchemes.indexOf(a.protocol) >= 0) { return s; }
      return null;
    } catch (e) {
      return null;
    }
  };

  // Y.linkTo builds an anchor whose href may also use one of the given schemes.
  // The anchor is built without an href and the attribute set afterwards, so
  // Y.el's own gate -- which is the strict one -- is not the thing deciding.
  Y.linkTo = function (url, schemes, attrs, children) {
    var a = Y.el('a', attrs, children);
    var safe = Y.safeUrl(url, schemes);
    if (safe !== null) { a.setAttribute('href', safe); }
    return a;
  };

  function appendKid(parent, kid) {
    if (kid === null || kid === undefined) { return; }
    // Arrays flatten so a caller may hand over a built list of cells; a string
    // must NOT, because its .length would make it look like one.
    if (Array.isArray(kid)) {
      for (var i = 0; i < kid.length; i++) { appendKid(parent, kid[i]); }
      return;
    }
    parent.appendChild(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }

  // Y.el builds an element, escaping by construction: `text` goes through
  // textContent and every child that is not already a node becomes a text node.
  //
  // Children may be passed either as further arguments or as an array, because
  // the service UIs were written against both shapes and neither reads wrong:
  //   Y.el('tr', null, [tdA, tdB])
  //   Y.el('form', null, input, submit, cancel)
  // An attribute whose value is null or undefined is dropped rather than
  // rendered as the string "null", which is what lets a caller propagate "no
  // usable URL" straight into an href.
  Y.el = function (tag, attrs) {
    var e = document.createElement(tag);
    if (attrs) {
      for (var k in attrs) {
        if (!has(attrs, k)) { continue; }
        var v = attrs[k];
        if (v === null || v === undefined) { continue; }
        if (k === 'class') { e.className = v; }
        else if (k === 'text') { e.textContent = v; }
        else if (k.indexOf('on') === 0 && typeof v === 'function') { e.addEventListener(k.slice(2), v); }
        else if (k === 'href' || k === 'src') { var safe = Y.safeUrl(v); if (safe !== null) { e.setAttribute(k, safe); } }
        else { e.setAttribute(k, v); }
      }
    }
    for (var i = 2; i < arguments.length; i++) { appendKid(e, arguments[i]); }
    return e;
  };

  // Y.append adds children to an existing element, taking the same shapes Y.el
  // takes for its own: nodes, strings, arrays of either, and nulls that are
  // skipped. appendChild under it, not ChildNode.append (Safari 10+).
  Y.append = function (el) {
    for (var i = 1; i < arguments.length; i++) { appendKid(el, arguments[i]); }
    return el;
  };

  // Y.replace swaps all of el's children for the given nodes. removeChild +
  // appendChild, not Element.replaceChildren (Safari 14+) and not innerHTML.
  Y.replace = function (el) {
    while (el.firstChild) { el.removeChild(el.firstChild); }
    for (var i = 1; i < arguments.length; i++) { appendKid(el, arguments[i]); }
    return el;
  };

  // Y.detach removes a node without ChildNode.remove (Safari 10+).
  Y.detach = function (node) {
    if (node && node.parentNode) { node.parentNode.removeChild(node); }
  };

  // --- JSON client ---------------------------------------------------------

  // isPlainBody reports whether a body is a bag of fields to serialize as JSON
  // rather than something the browser must send as-is. A FormData upload is the
  // case that matters: stringifying one would post "[object FormData]" and
  // naming it application/json would strip the multipart boundary the daemon
  // parses the file out of.
  function isPlainBody(v) {
    if (typeof v !== 'object' || v === null) { return false; }
    if (typeof window.FormData !== 'undefined' && v instanceof window.FormData) { return false; }
    if (typeof window.Blob !== 'undefined' && v instanceof window.Blob) { return false; }
    if (typeof window.ArrayBuffer !== 'undefined' && v instanceof window.ArrayBuffer) { return false; }
    if (typeof window.URLSearchParams !== 'undefined' && v instanceof window.URLSearchParams) { return false; }
    if (v.nodeType) { return false; }
    return true;
  }

  // Y.api is the one way these UIs talk to their daemon. It accepts both call
  // shapes the services grew: a plain object body, which it serializes and
  // labels as JSON, or a body the caller already stringified (or built as
  // FormData) with its own headers. Anything else in opts is passed through to
  // fetch.
  //
  // The error it throws carries the machine-readable parts alongside the
  // message: a caller has to tell "you are not unlocked" from "that failed",
  // and matching on a message string breaks the moment the wording changes.
  //
  // opts.timeoutMs (default 10s) bounds the wait so a stalled daemon cannot
  // hang a page load forever. Where AbortController is missing the request is
  // ABANDONED rather than canceled -- the caller's rejection is on time either
  // way, and the socket closes when the response finally arrives or the browser
  // gives up on it.
  Y.api = function (path, opts) {
    opts = opts || {};
    var init = {};
    for (var k in opts) {
      if (has(opts, k) && k !== 'timeoutMs' && k !== 'body' && k !== 'headers') { init[k] = opts[k]; }
    }
    init.method = opts.method || 'GET';
    var headers = opts.headers ? Object.assign({}, opts.headers) : {};
    if (opts.body !== null && opts.body !== undefined) {
      if (isPlainBody(opts.body)) {
        init.body = JSON.stringify(opts.body);
        if (!headers['Content-Type']) { headers['Content-Type'] = 'application/json'; }
      } else {
        // Sent untouched, and with no Content-Type of ours: a FormData body
        // carries a boundary only the browser can name.
        init.body = opts.body;
      }
    }
    init.headers = headers;

    var controller = (typeof window.AbortController !== 'undefined') ? new window.AbortController() : null;
    if (controller) { init.signal = controller.signal; }
    var xhr = null;
    if (!controller) { init.yurunaXhrOut = function (x) { xhr = x; }; }

    var timeoutMs = opts.timeoutMs > 0 ? opts.timeoutMs : 10000;
    var timedOut = false;
    var timer = window.setTimeout(function () {
      timedOut = true;
      if (controller) { controller.abort(); }
      else if (xhr && xhr.abort) { try { xhr.abort(); } catch (e) { /* already done */ } }
    }, timeoutMs);

    var settled = function () { if (timer) { window.clearTimeout(timer); timer = null; } };

    return window.fetch(path, init).then(function (res) {
      return res.json().then(function (d) { return d; }, function () { return {}; })
        .then(function (data) {
          settled();
          data = data || {};
          if (!res.ok || data.ok === false) {
            var err = new Error(data.error || data.reason || ('HTTP ' + res.status));
            err.status = res.status;
            err.reason = data.reason || '';
            err.body = data;
            throw err;
          }
          return data;
        });
    }, function (e) {
      settled();
      throw timedOut ? new Error('The request took too long and was given up on.') : e;
    });
  };

  // --- control proof -------------------------------------------------------

  // takeControlProof lifts the short-lived control proof the aggregator's /go/
  // redirect leaves in the URL fragment (#yctl=<expiry>.<proof>) and strips it
  // from the address bar, so it is not shoulder-surfed or pasted onward with
  // the URL. A fragment never reaches a server and never lands in an access
  // log, which is why the proof travels there and not in the query.
  //
  // Read once by construction: the second call finds no fragment.
  //
  // decode is the caller's, because the services do not agree and the
  // difference is not cosmetic: a proof is "<digits>.<standard base64>", where
  // a stray % would make decodeURIComponent throw on a value that was fine.
  Y.takeControlProof = function (decode) {
    try {
      var m = (window.location.hash || '').match(/(?:^#|[#&])yctl=([^&]+)/);
      if (!m || !m[1]) { return ''; }
      if (window.history && window.history.replaceState) {
        window.history.replaceState(null, document.title, window.location.pathname + window.location.search);
      }
      return decode ? decodeURIComponent(m[1]) : m[1];
    } catch (e) {
      // No history API: the proof still works, it just stays in the address bar.
      return decode ? '' : '';
    }
  };

  // startProofUnlock spends that proof on this service's session, once, at
  // load, so the gate is already open by the time a page reads it. Arriving
  // through a link on the Yuruna hosts dashboard is then enough to act -- the
  // operator is not sent back to copy the rotating code off a tile.
  //
  // Resolves false on anything short of a granted session (no fragment,
  // expired proof, aggregator unreachable), which leaves the lab-token prompt
  // as the way in. It is a shortcut, never the only door.
  Y.startProofUnlock = function (opts) {
    opts = opts || {};
    if (!Y.proofUnlock) {
      var proof = Y.takeControlProof(opts.decode);
      Y.proofUnlock = proof
        ? Y.api('/api/unlock-proof', { method: 'POST', body: { proof: proof } })
          .then(function () { return true; }, function () { return false; })
        : Promise.resolve(false);
    }
    return Y.proofUnlock;
  };

  // --- host facts ----------------------------------------------------------

  // hostInfo reads /api/hostinfo once and hands every later caller the same
  // answer: these are facts about the daemon, and they do not change under a
  // loaded page. Never rejects -- a failed read resolves to {} so a caller
  // renders a missing field rather than losing its whole table to a failed
  // furniture fetch.
  var hostInfoPromise = null;
  Y.hostInfo = function () {
    if (!hostInfoPromise) {
      hostInfoPromise = Y.api('/api/hostinfo').then(
        function (d) { return d || {}; },
        // Only success is memoized. A failure that stuck would hold gated
        // controls off for the life of the page over one unlucky moment at
        // load; releasing it lets the next read pick the answer up as soon as
        // the daemon is back.
        function () { hostInfoPromise = null; return {}; }
      );
    }
    return hostInfoPromise;
  };

  // --- formatting ----------------------------------------------------------

  Y.shortHost = function (h) { return h ? String(h).slice(0, 8) : '?'; };

  // How a FULL opaque id is spelled wherever one is shown: 8-4-4-4-12, the same
  // form the Yuruna hosts dashboard reveals and every pool-admin command accepts
  // as pasted. 32 undifferentiated hex characters are not checkable against
  // another screen by eye, and a lab holds a dozen that share the '42' prefix.
  // The stores are keyed on the undashed form, so this is a rendering: nothing
  // that goes back to a server may be built from it. A value that is not 32 hex
  // passes through untouched.
  Y.guid = function (id) {
    var h = String(id === null || id === undefined ? '' : id);
    if (!/^[0-9a-fA-F]{32}$/.test(h)) { return h; }
    return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join('-');
  };

  // Binary units, because the operator compares these against a NAS free-space
  // figure and every tool that reports one uses GiB.
  Y.bytes = function (n) {
    if (!n) { return '0 B'; }
    var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var i = 0;
    var v = Number(n);
    if (!Number.isFinite(v)) { return '0 B'; }
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v.toFixed(0) : v.toFixed(v < 10 ? 2 : 1)) + ' ' + units[i];
  };

  // The stash listing's size column, which reads in the units the upload dialog
  // that produced the file used. Deliberately not Y.bytes: the two answer
  // different questions and rounding one into the other would misreport both.
  Y.humanSize = function (n) {
    if (n === null || n === undefined) { return ''; }
    var u = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var v = Number(n);
    // A non-numeric / non-finite size falls back to the same empty placeholder
    // as null instead of rendering 'NaN B'.
    if (!Number.isFinite(v)) { return ''; }
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v : v.toFixed(1)) + ' ' + u[i];
  };

  Y.duration = function (seconds) {
    var s = Math.round(Number(seconds));
    if (!Number.isFinite(s)) { return '--'; }
    var abs = Math.abs(s);
    if (abs < 60) { return s + 's'; }
    if (abs < 3600) { return Math.round(s / 60) + 'm'; }
    if (abs < 86400) { return (s / 3600).toFixed(1) + 'h'; }
    return (s / 86400).toFixed(1) + 'd';
  };

  Y.stamp = function (iso) {
    if (!iso) { return '--'; }
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return iso; }
    return d.toLocaleString();
  };

  Y.fmtDate = function (iso) {
    if (!iso) { return ''; }
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return iso; }
    return d.toLocaleString();
  };

  // --- notices and feedback ------------------------------------------------

  // The page's single banner, for a page that carries one.
  Y.notice = function (kind, msg) {
    var n = document.getElementById('notice');
    if (!n) { return; }
    n.className = 'notice ' + kind;
    n.textContent = msg;
    n.style.display = 'block';
  };
  Y.clearNotice = function () {
    var n = document.getElementById('notice');
    if (n) { n.style.display = 'none'; n.textContent = ''; }
  };

  // A per-row action's outcome belongs where the action was. At 400% zoom a
  // banner at the top of <main> and a button forty rows down are never on
  // screen together, so a magnifier user presses Delete and sees nothing
  // happen. role="status" means a screen reader hears it too, and
  // block:'nearest' scrolls the minimum needed rather than yanking the page.
  Y.rowFeedback = function (rowEl, kind, text) {
    if (!rowEl) { return; }
    var host = rowEl.querySelector('.row-feedback');
    if (!host) {
      host = document.createElement('div');
      host.className = 'row-feedback';
      host.setAttribute('role', 'status');
      var last = rowEl.lastElementChild || rowEl;
      last.appendChild(host);
    }
    host.className = 'row-feedback ' + (kind || '');
    host.textContent = text || '';
    if (rowEl.scrollIntoView) { rowEl.scrollIntoView({ block: 'nearest' }); }
  };

  // A repaint that wipes its container takes the focused control with it: the
  // node leaves the document, focus falls to <body>, and any half-typed value
  // in it is gone. On a 5-second poll a keyboard user cannot finish a row
  // action before the row is rebuilt underneath them, and on a 60-second one a
  // half-entered id disappears every minute.
  //
  // So hold the repaint while someone is working INSIDE the region and run it
  // once focus leaves. The data is then at most one interval stale, and only
  // while a user is actively in that region -- which is exactly when they do
  // not want it moving under them. Y.sortTable takes the other route (leave
  // correct rows in place) for the same reason.
  Y.holdRepaint = function (region, rerun) {
    if (!region || typeof rerun !== 'function') { return false; }
    var active = document.activeElement;
    if (!active || active === document.body || !region.contains(active)) { return false; }
    if (region.getAttribute('data-repaint-held') === '1') { return true; }
    region.setAttribute('data-repaint-held', '1');
    var release = function (ev) {
      // focusout also fires moving BETWEEN children; resume only once focus has
      // genuinely left the region.
      if (ev && ev.relatedTarget && region.contains(ev.relatedTarget)) { return; }
      region.removeEventListener('focusout', release);
      region.removeAttribute('data-repaint-held');
      rerun();
    };
    region.addEventListener('focusout', release);
    return true;
  };

  // --- waiting -------------------------------------------------------------

  // How long a container that ALREADY holds rows keeps them before the wait
  // indicator replaces them. A read that answers in 50 ms would otherwise blink
  // the table out and back, which reads as a glitch rather than as progress; a
  // read that is actually slow is announced long before anyone concludes the
  // page is stuck.
  var BUSY_GRACE_MS = 250;

  // The indicator row for a table, spanning every column so it sits under the
  // middle of the table rather than squeezed into the first one. The column
  // count comes from the header; a table without one gets a single wide cell,
  // which still renders.
  function busyRow(tbody, inner) {
    var table = tbody.closest ? tbody.closest('table') : null;
    var head = table ? table.querySelector('thead tr') : null;
    var cols = head ? head.children.length : 1;
    return Y.el('tr', { class: 'loading-row' }, [
      Y.el('td', { colspan: String(cols) }, [inner])
    ]);
  }

  // Y.busy paints "still working" into a container and returns the function
  // that takes it back down. Every slow read on every page goes through it, so
  // one wait looks like every other one.
  //
  //   var done = Y.busy(el, 'Loading pools...');
  //   try { ...render... } finally { done(); }
  //
  // done() must run on the FAILURE path too, or a read that never lands leaves
  // a spinner turning forever -- which claims progress that is not happening.
  //
  // A read that FAILED gets back what the indicator replaced: the rows are
  // stale, not wrong, and the page's notice already says the refresh did not
  // land. The originals go back, not copies of them, so the controls in those
  // rows keep the handlers they were built with. When the caller did repaint,
  // there is nothing to undo and done() leaves its work alone.
  //
  // An empty container shows the indicator at once -- there is nothing to lose,
  // and that first paint is the wait an operator is actually staring at.
  Y.busy = function (container, message) {
    if (!container) { return function () { }; }
    var inner = Y.el('div', { class: 'loading', role: 'status' }, [
      Y.el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      Y.el('span', { class: 'loading-text', text: message || 'Loading...' })
    ]);
    // A <tbody> may only hold rows, so there the indicator travels in one that
    // spans the table; every other container takes it directly.
    var node = container.tagName === 'TBODY' ? busyRow(container, inner) : inner;
    var previous = [];
    var timer = null;
    var paint = function () {
      timer = null;
      while (container.firstChild) { previous.push(container.removeChild(container.firstChild)); }
      container.appendChild(node);
    };
    if (container.firstElementChild) { timer = window.setTimeout(paint, BUSY_GRACE_MS); }
    else { paint(); }
    return function () {
      if (timer) { window.clearTimeout(timer); timer = null; }
      if (node.parentNode !== container) { return; }
      container.removeChild(node);
      for (var i = 0; i < previous.length; i++) { container.appendChild(previous[i]); }
      previous.length = 0;
    };
  };

  // Y.block raises a barrier over the whole page and returns the function that
  // takes it down.
  //
  //   var done = Y.block('Deleting...');
  //   try { ...work... } finally { done(); }
  //
  // It exists for destructive work, where the page on screen is about to stop
  // being true: a row whose bytes are already gone still offers Download, and
  // the operator has no way to know the difference. Refusing every input for
  // the duration is the only honest state -- the alternative is a page that
  // takes an action and then explains it could not have worked.
  //
  // done() MUST run on the failure path too. A request that never lands would
  // otherwise leave the page permanently unusable, which is a worse fault than
  // the confusion the barrier prevents.
  //
  // The barrier swallows input from the moment it is raised; only its
  // APPEARANCE waits out the grace period, so a delete that answers in 80 ms
  // does not flash a scrim over the table. The two halves are deliberately not
  // synchronized: looking live while refusing clicks merely feels unresponsive,
  // whereas looking blocked while still accepting them is the exact fault this
  // is here to prevent.
  Y.block = function (message) {
    if (typeof document === 'undefined' || !document.body) { return function () { }; }
    var box = Y.el('div', { class: 'blocking-box' },
      Y.el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      // aria-live, so a screen reader announces the wait it cannot see. The
      // text is the element's whole content, so polite is enough -- there is
      // nothing here to interrupt.
      Y.el('span', { class: 'blocking-text', role: 'status', 'aria-live': 'polite', text: message || 'Working...' }));
    var overlay = Y.el('div', { class: 'blocking', 'aria-busy': 'true' }, box);
    document.body.appendChild(overlay);

    // A scrim stops the pointer, not the keyboard: a Tab from wherever focus
    // sat lands on a link underneath it, and the barrier would be a picture of
    // a blocked page rather than a blocked one.
    //
    // Contain focus rather than suppress Tab. Swallowing the key leaves the
    // keyboard user pressing a key that does nothing, with no indication why;
    // moving focus INTO the box means Tab still works, the wait is where focus
    // already is, and the announcement the box carries is read on arrival.
    var previousFocus = document.activeElement;
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.tabIndex = -1;
    var trap = function (e) {
      if (Y.key(e) !== 'Tab') { return; }
      // One focusable node in the box, so every Tab lands back on it.
      e.preventDefault();
      box.focus();
    };
    document.addEventListener('keydown', trap, true);
    box.focus();

    var timer = window.setTimeout(function () { timer = null; overlay.className = 'blocking shown'; }, BUSY_GRACE_MS);
    return function () {
      if (timer) { window.clearTimeout(timer); timer = null; }
      document.removeEventListener('keydown', trap, true);
      Y.detach(overlay);
      // Only if it is still there to focus: the work that just finished may
      // well have removed the row this button belonged to.
      if (previousFocus && previousFocus.focus && previousFocus.parentNode) { previousFocus.focus(); }
    };
  };

  // --- table furniture -----------------------------------------------------

  // httpBase gates what may become an href: an absolute http origin, trailing
  // slashes trimmed, or '' to render an id unlinked. The daemon already forces
  // the scheme, so this is the second of two checks rather than the only one --
  // it is here because the value reaches an href, and neither a
  // javascript:/data: URL from a mistyped flag nor an https one that would
  // raise a certificate warning should get there on one guard alone.
  Y.httpBase = function (v) {
    var s = String(v === null || v === undefined ? '' : v).replace(/^\s+|\s+$/g, '').replace(/\/+$/, '');
    if (!s) { return ''; }
    try {
      var a = document.createElement('a');
      a.href = s;
      return a.protocol === 'http:' ? s : '';
    } catch (e) {
      return '';
    }
  };

  // Y.hostLink renders a host id as its first 8 characters, linked to that
  // host's own status page through the aggregator's /go/host redirect -- the
  // same hop the Yuruna hosts dashboard's Control column takes, which resolves
  // the host's CURRENT IP server-side (so the link survives a DHCP change) and
  // hands the browser a short-lived control proof.
  //
  // With no aggregator to redirect through, the id renders as unlinked text: a
  // link that cannot resolve reads as a broken page, while a bare id still
  // identifies the host. The full id is always on the title, because 8
  // characters identify but do not copy -- and it is spelled the way Y.guid
  // spells one, while the href carries the undashed key the pool is on.
  Y.hostLink = function (hostId, poolId, goBaseUrl) {
    var full = String(hostId === null || hostId === undefined ? '' : hostId);
    if (!full) { return Y.el('span', { class: 'muted', text: '--' }); }
    var base = Y.httpBase(goBaseUrl);
    if (!base) { return Y.el('span', { class: 'mono', text: Y.shortHost(full), title: Y.guid(full) }); }
    var url = base + '/go/host?host=' + encodeURIComponent(full) + '&pool=' + encodeURIComponent(poolId || '');
    return Y.el('a', { class: 'mono', href: url, target: '_blank', rel: 'noopener', title: Y.guid(full) }, Y.shortHost(full));
  };

  // Y.idCell renders an opaque id as its first 8 characters -- the same prefix
  // the header's "Host:" shows, and enough to tell two apart at a glance --
  // expanding on click to the full id as Y.guid spells it, because quoting one
  // into a command needs all of it and a hyphenated id is the form those
  // commands take.
  //
  // A <button>, not a click handler on a <span>: it is an interactive control,
  // so keyboard activation and the screen-reader announcement have to come with
  // it rather than be reimplemented.
  Y.idCell = function (id) {
    var full = Y.guid(id);
    if (!full) { return Y.el('span', { class: 'muted', text: '--' }); }
    var short = Y.shortHost(full);
    var btn = Y.el('button', { type: 'button', class: 'id-toggle mono', text: short, title: 'Show the full id' });
    btn.addEventListener('click', function () {
      var expanded = btn.textContent === full;
      btn.textContent = expanded ? short : full;
      btn.title = expanded ? 'Show the full id' : 'Show only the first 8 characters';
    });
    return btn;
  };

  // Y.numCell is the counter column a table opens with. It numbers the row
  // where it SITS, not the thing in it: the column reads 1..N down the page
  // whatever the table is sorted by, so "how many hosts are there" and "the
  // fourth one down" are answerable without counting. A non-positive n renders
  // blank, which is what a totals row in tfoot passes.
  Y.numCell = function (n) {
    return Y.el('td', { class: 'rownum', text: n > 0 ? String(n) : '' });
  };

  // Y.sortTable orders a table by its column headers, over rows the page has
  // already built. A header opts in by carrying data-sort="<key>" around a
  // <button class="sort">; the page hands over { tr, values } per row, and
  // values[key] is what that column sorts on. A header without data-sort is a
  // column no order would mean anything for -- the counter, a cell that is only
  // an action button -- and stays inert.
  //
  // It reorders the EXISTING row nodes rather than asking the page to build
  // them again. A row on these pages can hold a hostId someone is halfway
  // through typing or a test set picked but not yet assigned, and rebuilding
  // would take that away as the price of reading the table another way.
  //
  // Returns { set, refresh }: set(rows) replaces what the table holds,
  // refresh() re-sorts the same rows after their values changed underneath (a
  // column fed by a slower endpoint than the one the rows came from).
  //
  // opts.compare, when given, replaces the default comparison for a table whose
  // order is not the alphabet -- a state column where "failed" is the row the
  // operator is looking for, not the row the letter f puts first.
  Y.sortTable = function (tbody, opts) {
    opts = opts || {};
    var table = tbody && tbody.closest ? tbody.closest('table') : null;
    var key = opts.key || '';
    var asc = opts.asc !== false;
    var rows = [];

    function headers() {
      return table ? table.querySelectorAll('th[data-sort]') : [];
    }

    // Strings compare lowercased -- a display name's capitalization is not an
    // order anyone means to ask for -- and a missing value becomes '', which
    // the comparison ranks last. Numbers pass through: 0 members is a value.
    function cmpValue(v) {
      if (typeof v === 'string') { return v.toLowerCase(); }
      return (v === null || v === undefined) ? '' : v;
    }

    function compare(a, b) {
      var cmp;
      if (typeof opts.compare === 'function') {
        cmp = opts.compare(a, b, key);
      } else {
        var av = cmpValue(a.values ? a.values[key] : '');
        var bv = cmpValue(b.values ? b.values[key] : '');
        cmp = 0;
        if (av !== bv) {
          // A row with no value ranks last ascending: sorting on a column is a
          // way of reading the rows that HAVE one, and every one of these
          // tables has blanks -- a pool with no test set, a host that never
          // answered.
          if (av === '') { cmp = 1; }
          else if (bv === '') { cmp = -1; }
          else { cmp = av < bv ? -1 : 1; }
        }
      }
      return asc ? cmp : -cmp;
    }

    // Sorted from the order the page built the rows in, not from the order they
    // are in now, so ties land the same way every time: the sort is stable, and
    // that build order is the server's.
    //
    // Rows already standing in the right order are left where they are.
    // Re-appending a node moves it, and moving one that holds the focus takes
    // the caret out of whatever is being typed into it -- which is what a
    // repaint for a column fed by a slow endpoint would otherwise do, seconds
    // after the operator started typing.
    function paint() {
      var ordered = key ? rows.slice().sort(compare) : rows.slice();
      var placed = tbody.children.length === ordered.length;
      for (var i = 0; placed && i < ordered.length; i++) {
        placed = tbody.children[i] === ordered[i].tr;
      }
      if (!placed) { tbody.textContent = ''; }
      for (var j = 0; j < ordered.length; j++) {
        var r = ordered[j];
        var n = j + 1;
        var cell = r.tr.firstElementChild;
        if (!cell || !cell.className || cell.className.indexOf('rownum') < 0) {
          cell = Y.numCell(n);
          r.tr.insertBefore(cell, r.tr.firstChild);
        }
        cell.textContent = String(n);
        if (!placed) { tbody.appendChild(r.tr); }
      }
    }

    // aria-sort on the header cell is what a screen reader announces and what
    // draws the arrow, so the two cannot disagree.
    function mark() {
      var ths = headers();
      for (var i = 0; i < ths.length; i++) {
        var th = ths[i];
        if (th.getAttribute('data-sort') === key) { th.setAttribute('aria-sort', asc ? 'ascending' : 'descending'); }
        else { th.removeAttribute('aria-sort'); }
      }
    }

    var thList = headers();
    for (var i = 0; i < thList.length; i++) {
      (function (th) {
        var btn = th.querySelector('button.sort');
        if (!btn) { return; }
        btn.addEventListener('click', function () {
          var k = th.getAttribute('data-sort');
          if (k === key) { asc = !asc; }
          else { key = k; asc = true; }
          mark();
          paint();
        });
      }(thList[i]));
    }
    mark();

    return {
      set: function (list) { rows = (list || []).slice(); paint(); },
      refresh: paint,
      // Read back for a page that persists the operator's chosen order.
      state: function () { return { key: key, asc: asc }; }
    };
  };

  // A CLOSED <select> fires `change` on every arrow press on the dominant
  // platform, so committing on `change` fires the action once per keystroke
  // while the user is still choosing -- a confirm dialog per arrow key, which
  // counts as a change of context on input. Commit when the value has SETTLED
  // instead: immediately for a pointer selection, which is already final, and
  // on Enter or blur for a keyboard one.
  //
  // Detecting the difference by whether the select still holds focus does not
  // work: a mouse selection leaves focus on it too. The navigation key is the
  // signal.
  Y.onSelectCommit = function (sel, commit) {
    var NAV = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'];
    var byKey = false;
    var pending = false;
    sel.addEventListener('keydown', function (ev) {
      var k = Y.key(ev);
      if (k === 'Enter' && pending) { ev.preventDefault(); pending = false; commit(); return; }
      byKey = NAV.indexOf(k) >= 0;
    });
    sel.addEventListener('change', function () {
      if (byKey) { pending = true; } else { commit(); }
      byKey = false;
    });
    sel.addEventListener('blur', function () {
      if (pending) { pending = false; commit(); }
    });
  };

  // --- page chrome ---------------------------------------------------------

  // A reader who needs the page to hold still needs it to hold still on the
  // next page too, so the choice is stored rather than held in the tab. The
  // countdown was read-only and Refresh only ever made the page update SOONER;
  // nothing could make it stop.
  var PAUSE_KEY = 'yuruna.autorefresh.paused';
  Y.autoPaused = function () {
    try { return window.localStorage.getItem(PAUSE_KEY) === '1'; } catch (e) { return false; }
  };
  Y.wirePause = function (onResume) {
    var btn = document.getElementById('footer-pause');
    if (!btn) { return; }
    var paint = function () {
      var p = Y.autoPaused();
      btn.setAttribute('aria-pressed', p ? 'true' : 'false');
      btn.textContent = p ? 'Resume' : 'Pause';
      // The countdown is the visible evidence of the state; freeze the word
      // rather than a number that is no longer counting down to anything.
      var el = document.getElementById('countdown');
      if (el && p) { el.textContent = 'paused'; }
    };
    btn.addEventListener('click', function () {
      var next = !Y.autoPaused();
      try { window.localStorage.setItem(PAUSE_KEY, next ? '1' : '0'); } catch (e) { /* private mode */ }
      paint();
      if (!next && typeof onResume === 'function') { onResume(); }
    });
    paint();
  };

  // initHeader fills the shared header's two variable slots: the daemon version
  // under the service name, and this host's id. Page-agnostic -- both facts
  // come from /api/hostinfo, so a page gets them by carrying the markup. A
  // failure leaves the slots empty rather than blocking the page: they are
  // decoration, and every page here works without them.
  Y.initHeader = function () {
    return Y.hostInfo().then(function (d) {
      var ver = document.getElementById('header-version');
      if (ver && d.version) { ver.textContent = 'v' + d.version; }
      var machine = document.getElementById('machine');
      if (machine && d.localHostId) { machine.textContent = 'Host: ' + Y.shortHost(d.localHostId); }
      return d;
    });
  };

  // initFooter wires the shared bottom bar (server IPs, last-loaded time,
  // refresh countdown). Page-agnostic: host facts come from /api/hostinfo, the
  // countdown is visibility-aware (default 60 s), and the returned markLoaded
  // lets a page stamp the "Loaded" time and reset the countdown when ITS data
  // refreshes. At zero it invokes opts.refresh (default: a full reload). A
  // no-op on a page without the markup.
  //
  // The countdown is opt-in through the markup: a page that carries no
  // #countdown starts no tick and is never reloaded from under the operator,
  // which is what a page holding an unsaved form needs.
  //
  // opts.paused is the finer-grained form of the same protection: a page that
  // normally auto-refreshes can park the countdown for as long as a refresh
  // would destroy transient state the operator built by hand. The displayed
  // number freezes where it stands and resumes once the predicate goes false.
  //
  // Returns { markLoaded, stamp, busy }.
  Y.initFooter = function (opts) {
    opts = opts || {};
    var interval = opts.intervalSeconds > 0 ? opts.intervalSeconds : 60;
    var refresh = typeof opts.refresh === 'function' ? opts.refresh : function () { window.location.reload(); };
    var paused = typeof opts.paused === 'function' ? opts.paused : null;
    // Pages that already reload their own data on visibilitychange pass false,
    // so returning to the tab does not fire two fetches a second apart.
    var refreshOnVisible = opts.refreshOnVisible !== false;
    var $ = function (id) { return document.getElementById(id); };
    var countdown = interval;

    // Render IPs into the readonly textarea, sized to 1-2 rows (one per address
    // family). These are the daemon's own IPs, but use .value (never innerHTML)
    // anyway. Em dash (--) is the empty placeholder.
    var renderIps = function (text) {
      var el = $('footer-ip-list');
      if (!el) { return; }
      var v = (text || '').replace(/\s+$/, '');
      el.value = v || '--';
      el.rows = Math.min(2, Math.max(1, el.value.split('\n').length));
    };

    var stamp = function () {
      var el = $('last-loaded');
      if (el) { el.textContent = new Date().toLocaleTimeString(); }
    };
    var markLoaded = function () { stamp(); countdown = interval; };

    // The footer's activity dot: what a refresh the operator did NOT ask for
    // signals with. A background poll keeps the numbers it is refreshing on
    // screen, so it has no room for Y.busy's indicator -- and a wall display
    // that blanked every half minute would read as failing, not as refreshing.
    //
    // Depth-counted: a page whose load runs two reads at once must not have the
    // first one to finish declare the page idle.
    var busyDepth = 0;
    var busy = function (on) {
      busyDepth = Math.max(0, busyDepth + (on ? 1 : -1));
      var el = $('footer-busy');
      if (el) { el.hidden = busyDepth === 0; }
    };

    // Stamp here, not only from a page's data load: a page with no feed of its
    // own would otherwise show the em-dash forever. A page that does fetch
    // overwrites this a moment later with its own load time. stamp, not
    // markLoaded -- arriving host facts must not restart a countdown a caller
    // may already be running. A failed read leaves the time at its placeholder:
    // an unreachable daemon must not be stamped as a successful load.
    Y.hostInfo().then(function (d) {
      renderIps(d.serverIps);
      if (d.ok) { stamp(); }
    });

    // A <button>, not an <a href="#">: it never navigated, so announcing it as
    // a link misdescribed it and it did not answer Space.
    var refreshBtn = $('footer-refresh');
    if (refreshBtn) { refreshBtn.addEventListener('click', function () { window.location.reload(); }); }

    // One-second tick. A hidden tab parks the countdown ('...') and never
    // refreshes, so a backgrounded page does not poll; returning to the
    // foreground forces a refresh on the next tick (countdown driven to 0).
    if ($('countdown')) {
      window.setInterval(function () {
        var el = $('countdown');
        if (!el) { return; }
        if (document.hidden) { el.textContent = '...'; return; }
        // The operator's own choice first: opts.paused is the page's internal
        // guard (a delete in flight, a selection standing), and Y.autoPaused is
        // the user-facing one.
        if (Y.autoPaused()) { return; }
        if (paused && paused()) { el.title = 'Auto-refresh paused'; return; }
        el.title = '';
        countdown = Math.max(0, countdown - 1);
        el.textContent = countdown;
        if (countdown === 0) { countdown = interval; refresh(); }
      }, 1000);
      Y.wirePause(function () {
        countdown = interval;
        var el = $('countdown');
        if (el) { el.textContent = countdown; }
      });
      if (refreshOnVisible) {
        document.addEventListener('visibilitychange', function () { if (!document.hidden) { countdown = 0; } });
      }
    }

    return { markLoaded: markLoaded, stamp: stamp, busy: busy };
  };

  // initChrome is the header and the footer together, for the pages that carry
  // both. Returns what initFooter returns.
  Y.initChrome = function (opts) {
    Y.initHeader();
    return Y.initFooter(opts);
  };

  // initMenu wires the header's page menu: the button toggles the panel, and a
  // click outside it or Escape closes it. The links are static markup, so every
  // page stays reachable even if this never runs.
  Y.initMenu = function () {
    var button = document.getElementById('menu-button');
    var panel = document.getElementById('menu-panel');
    if (!button || !panel) { return; }

    var setOpen = function (open) {
      panel.hidden = !open;
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
    };
    setOpen(false);

    button.addEventListener('click', function () {
      var open = button.getAttribute('aria-expanded') === 'true';
      setOpen(!open);
      if (!open) {
        var first = panel.querySelector('a');
        if (first) { first.focus(); }
      }
    });
    // The button's own handler runs first (target phase), so by the time this
    // bubble-phase listener sees the same click the panel is already open --
    // hence the button check, which stops it closing again immediately.
    document.addEventListener('click', function (e) {
      if (panel.hidden || panel.contains(e.target) || button.contains(e.target)) { return; }
      setOpen(false);
    });
    document.addEventListener('keydown', function (e) {
      if (Y.key(e) === 'Escape' && !panel.hidden) { setOpen(false); button.focus(); }
    });
  };

  // The header and its menu are on every page of every service, and not every
  // page has a script that would wire them, so they are wired here rather than
  // left to each one. The menu in particular is how you leave a page.
  //
  // Scripts load at the end of <body>, so the DOM is normally parsed already;
  // the guard covers a page that ever moves them into <head>.
  function initPageChrome() { Y.initMenu(); Y.initHeader(); }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initPageChrome);
  } else {
    initPageChrome();
  }
}(window, document));
