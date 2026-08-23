// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// What the pool-control UI adds to the shared runtime: the Lab-token gate.
// Everything page-agnostic -- Y.el, Y.api, the chrome, the table furniture --
// comes from /assets/yuruna.core.js, which every page loads first.
//
// ES5 ONLY. See the header of yuruna.core.js for why, and run
// tools/Invoke-Es5Check.ps1 before shipping a change here.
(function (window, document) {
  'use strict';

  var Y = window.Y;

  // Reads are open, so nothing here runs on arrival. The proof is spent at load
  // anyway, because a fast click must not race past the exchange into a
  // lab-token prompt it did not need.
  //
  // Taken raw, not decodeURIComponent'd: the proof is
  // "<digits>.<standard base64>", which has nothing to decode, and a stray %
  // would only make it throw.
  var proofUnlock = Y.startProofUnlock({ decode: false });

  // Y.ready resolves once that exchange has settled, for a page whose READ
  // depends on the session (a field served only to an unlocked request). Such a
  // page must not fetch before the proof has been spent, or its first paint
  // says "locked" to an operator who arrived holding the credential.
  Y.ready = function () { return proofUnlock; };

  // needsUnlock reports whether an error means "not unlocked" rather than "that
  // operation failed". 401 is the gate refusing; auth-unconfigured is the gate
  // refusing because this service has no way to check a credential at all --
  // both leave the change unmade, and neither is worth an alert box the
  // operator cannot act on.
  Y.needsUnlock = function (err) {
    return !!err && (err.status === 401 || err.reason === 'auth-unconfigured');
  };

  // Y.unlock prompts for the dashboard's Lab token and exchanges it for a
  // session. It builds its own markup so every page gets the prompt without
  // carrying a copy of it, and resolves true only when the unlock landed -- a
  // caller retries its change on true and gives up on false.
  //
  // It appears at the moment a change is attempted, which is also the moment
  // the operator has a reason to go and read the rotating code off the
  // dashboard.
  Y.unlock = function () {
    return new Promise(function (resolve) {
      var existing = document.getElementById('yuruna-unlock');
      if (existing) { Y.detach(existing); }

      var input = Y.el('input', {
        id: 'yuruna-unlock-code', type: 'text', maxlength: '6', spellcheck: 'false',
        autocapitalize: 'off', autocomplete: 'one-time-code',
        placeholder: 'Lab token', 'aria-label': 'Lab token'
      });
      // role="alert": a rejected token is the one message standing between the
      // operator and every gated control, so it has to be announced.
      var error = Y.el('p', { class: 'login-error', role: 'alert' });
      error.hidden = true;
      var submit = Y.el('button', { type: 'submit', text: 'Unlock' });
      var cancel = Y.el('button', { type: 'button', class: 'secondary', text: 'Cancel' });
      var form = Y.el('form', null, [input, submit, cancel]);
      // h2, not h1: every page carries its own h1, and a second one here would
      // claim the page has two subjects. role/aria-modal/aria-labelledby make
      // this an actual dialog rather than a section that merely looks like one.
      var heading = Y.el('h2', { id: 'yuruna-unlock-title', text: 'Enter the Lab token' });
      var panel = Y.el('section', {
        class: 'login', role: 'dialog', 'aria-modal': 'true',
        'aria-labelledby': 'yuruna-unlock-title'
      }, [
        heading,
        Y.el('p', {
          class: 'login-hint',
          // The deadline is what the reader acts on, and it is not the minute
          // the minting rotates on: the gate accepts the current code plus its
          // two predecessors, so a code just read stays good for at least one
          // full rotation and usually about three minutes. A 60-second sprint
          // would hurry exactly the people this wording is for -- anyone
          // reading a six-character confusable code with a magnifier or a
          // screen reader.
          text: "The 6-character code on the Yuruna hosts dashboard's Lab token tile. A code you have just read stays valid for about three minutes, so there is no need to rush it."
        }),
        form, error
      ]);
      var overlay = Y.el('div', { id: 'yuruna-unlock', class: 'unlock-overlay' }, panel);

      // Y.mutate resumes the original request after this resolves, so losing
      // focus here loses the operator's place in the middle of their own change.
      var opener = document.activeElement;
      var close = function (ok) {
        document.removeEventListener('keydown', onKey, true);
        Y.detach(overlay);
        if (opener && opener.parentNode && opener.focus) { opener.focus(); }
        resolve(ok);
      };
      var onKey = function (ev) {
        var k = Y.key(ev);
        if (k === 'Escape') { ev.preventDefault(); close(false); return; }
        if (k !== 'Tab') { return; }
        var stops = panel.querySelectorAll('button, input, [href], select, textarea, [tabindex]:not([tabindex="-1"])');
        if (!stops.length) { return; }
        var first = stops[0];
        var last = stops[stops.length - 1];
        if (ev.shiftKey && document.activeElement === first) { ev.preventDefault(); last.focus(); }
        else if (!ev.shiftKey && document.activeElement === last) { ev.preventDefault(); first.focus(); }
      };
      cancel.addEventListener('click', function () { close(false); });
      form.addEventListener('submit', function (ev) {
        ev.preventDefault();
        error.hidden = true;
        submit.disabled = true;
        Y.api('/api/login', { method: 'POST', body: { labToken: input.value.toLowerCase().replace(/^\s+|\s+$/g, '') } })
          .then(function () {
            close(true);
          }, function (e) {
            // The server cannot tell a wrong code from an expired one, so the
            // message has to carry the recovery step or the operator has no way
            // to know that retyping the same value is pointless.
            error.textContent = e.message +
              (Y.needsUnlock(e) ? ' The code on the dashboard tile rotates every 60 seconds; read it again and retype it.' : '');
            error.hidden = false;
            submit.disabled = false;
            input.select();
          });
      });
      document.body.appendChild(overlay);
      document.addEventListener('keydown', onKey, true);
      input.focus();
    });
  };

  // Y.mutate is Y.api for a request that CHANGES pool configuration: on a gate
  // refusal it prompts for the lab token and, if the unlock lands, sends the
  // same request again. Every mutating call site goes through it, so no page
  // has to decide for itself what a 401 means.
  Y.mutate = function (path, opts) {
    return proofUnlock.then(function () {
      return Y.api(path, opts);
    }).then(null, function (e) {
      if (!Y.needsUnlock(e)) { throw e; }
      return Y.unlock().then(function (ok) {
        if (!ok) { throw e; }
        return Y.api(path, opts);
      });
    });
  };
}(window, document));
