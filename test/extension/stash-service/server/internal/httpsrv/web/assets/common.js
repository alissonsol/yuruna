// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// What the stash UI adds to the shared runtime: the addresses of one stash, the
// class icon, and the lab-token gate. Everything page-agnostic -- Y.el, Y.api,
// the chrome, Y.block, the size and date formatting -- comes from
// /assets/yuruna.core.js, which every page loads first.
//
// Untrusted stash content is ALWAYS placed via textContent / safe DOM APIs,
// never innerHTML (section 7.4).
//
// ES5 ONLY. See the header of yuruna.core.js for why, and run
// tools/Invoke-Es5Check.ps1 before shipping a change here.
(function (window, document) {
  'use strict';

  var Y = window.Y;

  // Guards the one-time submit wiring in Y.initUnlock below.
  var unlockWired = false;

  // pathTail derives /<yyyy>/<mm>/<dd>/<id> from a view's permalink, which is
  // the authoritative /s/<host>/<yyyy>/<mm>/<dd>/<id> the server built.
  //
  // A malformed view (missing or non-string permalink) returns null instead of
  // throwing, so one bad row cannot crash the render of every other row.
  function pathTail(view) {
    if (!view || typeof view.permalink !== 'string') { return null; }
    var parts = view.permalink.split('/').filter(Boolean); // [s, host, y, m, d, id]
    return '/' + parts.slice(2).join('/');
  }

  // Propagate pathTail's null so a bad permalink yields no link: Y.el skips a
  // null href/src attribute rather than building a broken URL from it.
  Y.rawURL = function (view) {
    var tail = pathTail(view);
    return tail === null ? null : '/raw/' + view.hostId + tail;
  };
  Y.downloadURL = function (view) {
    var tail = pathTail(view);
    return tail === null ? null : '/download/' + view.hostId + tail;
  };

  // The REST endpoint for one listed stash (GET / DELETE). Same null
  // propagation: a malformed permalink yields no URL at all rather than a
  // DELETE aimed at a guessed path -- the caller must not destroy a stash it
  // could not address.
  Y.stashApiURL = function (view) {
    var tail = pathTail(view);
    return tail === null ? null : '/api/stashes/' + view.hostId + tail;
  };

  // The same stash as the bulk-delete API's field form. Null for a malformed
  // permalink, for the same reason stashApiURL is: a stash that cannot be
  // addressed exactly must not be named in a request that destroys things.
  Y.stashKey = function (view) {
    var tail = pathTail(view);
    if (tail === null) { return null; }
    var parts = tail.split('/').filter(Boolean); // [y, m, d, id]
    if (parts.length !== 4) { return null; }
    return { hostId: view.hostId, year: parts[0], month: parts[1], day: parts[2], id: parts[3] };
  };

  // Surrogate pairs, for two separate reasons. The \u{...} form these were
  // written in is ES2015: the baseline parser rejects it outright, and a parse
  // error here takes the whole file with it rather than just the icon. And the
  // pairs keep this source ASCII, so the bytes survive any tool in the path
  // that is not told the encoding.
  Y.classIcon = function (cls) {
    switch (cls) {
      case 'text': return '\uD83D\uDCC4';      // page
      case 'image': return '\uD83D\uDDBC';     // framed picture
      case 'pdf': return '\uD83D\uDCD5';       // closed book
      case 'audio': return '\uD83D\uDD0A';     // speaker
      case 'video': return '\uD83C\uDFAC';     // clapper
      case 'archive': return '\uD83D\uDCE6';   // package
      default: return '\uD83D\uDCBE';          // floppy
    }
  };

  // The one attempt to spend a control proof carried in from the Yuruna hosts
  // dashboard, started at load so the gate is already open by the time a page
  // reads it. Arriving through the dashboard's Extension hosts link is then
  // enough to delete -- the operator is not sent back to copy the rotating code
  // off a tile.
  //
  // Decoded, unlike the other services: this service's redirect percent-encodes
  // the fragment it hands over.
  Y.startProofUnlock({ decode: true });

  // Y.session reports what this browser may do. The proof is awaited rather
  // than raced: reading the gate first would render the lab-token prompt for a
  // device that was about to be unlocked anyway, and the prompt would then be
  // answered by an operator who never needed to see it. A failed read reports a
  // locked, unconfigured gate -- a page must offer no control it cannot vouch
  // for.
  Y.session = function () {
    return Y.proofUnlock.then(function () {
      return Y.api('/api/session');
    }).then(function (s) {
      return { authed: !!s.authed, labToken: !!s.labToken, configured: !!s.configured };
    }, function () {
      return { authed: false, labToken: false, configured: false };
    });
  };

  // Y.initUnlock wires the shared lab-token prompt: it shows the form only when
  // the gate is on and this device is not through it, names the case where no
  // gate is configured at all, and re-runs the page's own render after a
  // successful unlock so the controls appear without a reload. Resolves with
  // the session it read, so a caller gets the answer and the wiring from one
  // call.
  Y.initUnlock = function (onUnlocked) {
    return Y.session().then(function (sess) {
      var login = document.getElementById('login');
      var unconfigured = document.getElementById('gate-unconfigured');
      if (login) { login.hidden = !(sess.labToken && !sess.authed); }
      if (unconfigured) { unconfigured.hidden = sess.configured; }
      // The form is wired once for the page's life: initUnlock is called again
      // after every unlock and every reload, and a second listener on the same
      // form would submit the code twice.
      var form = document.getElementById('login-form');
      if (form && !unlockWired) {
        unlockWired = true;
        form.addEventListener('submit', function (ev) {
          ev.preventDefault();
          var field = document.getElementById('lab-token');
          var err = document.getElementById('login-error');
          if (err) { err.textContent = ''; }
          // Normalized here as well as at the daemon, so a code read off the
          // tile in capitals is not a round trip that comes back "incorrect".
          Y.api('/api/login', { method: 'POST', body: { labToken: field.value.trim().toLowerCase() } })
            .then(function () {
              field.value = '';
              if (typeof onUnlocked === 'function') { return onUnlocked(); }
              return null;
            }, function (e) {
              if (err) { err.textContent = e.message; }
            });
        });
      }
      return sess;
    });
  };
}(window, document));
