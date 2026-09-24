// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The small set of behavior a page with no shared runtime still needs.
//
// The pages built as Go string literals load neither yuruna.core.js nor
// yuruna.common.js, so everything those runtimes provide is absent: a bounded
// request, and a way to write a timestamp that does not change shape with the
// reader's device. Both are here in the smallest form those pages can carry.
(function (window) {
  'use strict';

  // The timer settles the caller's promise itself rather than waiting for the
  // transport to fail, so the rejection carries a message that says what
  // happened instead of whatever the aborted request eventually reports.
  window.yurunaRequest = function (url, timeoutMs) {
    var ms = timeoutMs > 0 ? timeoutMs : 10000;
    var controller = new window.AbortController();
    var init = { signal: controller.signal };

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
        controller.abort();
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
  // toLocaleTimeString is the obvious call and the wrong one: its shape comes
  // from the engine's own ICU data, which differs between browsers and moves
  // between releases, so the refresh stamp would not match what the rest of
  // the system writes for the same instant -- and the page has no shared
  // runtime to borrow the agreed formatter from.
  window.yurunaLocalTime = function (value) {
    var when = (value instanceof Date) ? value : new Date(value);
    if (isNaN(when.getTime())) { return ''; }
    var pad = function (n) { return n < 10 ? '0' + n : '' + n; };
    return pad(when.getHours()) + ':' + pad(when.getMinutes()) + ':' + pad(when.getSeconds());
  };
}(window));
