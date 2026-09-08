// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The small set of behavior a page with no shared runtime still needs.
//
// The pages built as Go string literals load neither yuruna.core.js nor
// yuruna.common.js, so everything those runtimes provide is absent: a bounded
// request, and a way to write a timestamp that does not change shape with the
// reader's device. Both are here in the smallest form those pages can carry.
//
// Composed onto yuruna.fetch-shim.js by tools/Invoke-CatalogEmbed.ps1; the
// request needs the stand-in's yurunaXhrOut handle when there is no native
// fetch.
//
// ES5 ONLY. The floor is Safari 9.0 / iOS 9.0.
(function (window) {
  'use strict';

  //
  // The timer settles the caller's promise itself rather than waiting for the
  // transport to fail. Between the two supported edges there is a browser with
  // a native fetch and no AbortController: nothing there can cancel the
  // request, and a timeout that could only abort would leave the caller
  // waiting forever on a promise that never settles -- a hang wearing a
  // timeout's clothes. Cancellation is still attempted where it is possible,
  // so the socket is freed; the caller is answered on time either way.
  window.yurunaRequest = function (url, timeoutMs) {
    var ms = timeoutMs > 0 ? timeoutMs : 10000;
    var controller = (typeof window.AbortController !== 'undefined') ? new window.AbortController() : null;
    var init = {};
    var xhr = null;
    if (controller) { init.signal = controller.signal; }
    else { init.yurunaXhrOut = function (x) { xhr = x; }; }

    return new Promise(function (resolve, reject) {
      var done = false;
      var timer = null;
      var finish = function (settle, value) {
        if (done) { return; }
        done = true;
        if (timer) { window.clearTimeout(timer); timer = null; }
        settle(value);
      };
      timer = window.setTimeout(function () {
        if (controller) { controller.abort(); }
        else if (xhr && xhr.abort) { try { xhr.abort(); } catch (e) { /* already done */ } }
        finish(reject, new Error('The request took too long and was given up on.'));
      }, ms);
      window.fetch(url, init).then(function (r) {
        if (!r.ok) { throw new Error('HTTP ' + r.status); }
        return r.json();
      }).then(function (data) {
        finish(resolve, data);
      }, function (e) {
        finish(reject, e);
      });
    });
  };

  // The time alone, in a shape that does not change with the reader's device.
  //
  // toLocaleTimeString is the obvious call and the wrong one: at the floor it
  // ignores the locale it is handed and answers in the browser's own, so the
  // refresh stamp on a page served in one language is written in another --
  // and the page has no shared runtime to borrow a formatter from.
  window.yurunaLocalTime = function (value) {
    var when = (value instanceof Date) ? value : new Date(value);
    if (isNaN(when.getTime())) { return ''; }
    var pad = function (n) { return n < 10 ? '0' + n : '' + n; };
    return pad(when.getHours()) + ':' + pad(when.getMinutes()) + ':' + pad(when.getSeconds());
  };
}(window));
