// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The request adapter for pages that carry no shared runtime.
//
// Most Yuruna pages load yuruna.core.js or yuruna.common.js and get this from
// there. Two pages do not: they are built as string literals inside their Go
// services and load nothing. Their application scripts still call fetch, so on
// a browser without one they render their static shell and then fill in
// nothing -- an empty table that looks like a lab with no data in it rather
// than like a page that failed.
//
// This file is the single source for every surface: the two shared browser
// runtimes carry it in their generated block, and the two Go services carry a
// generated copy beside them. tools/Invoke-CatalogEmbed.ps1 writes all four and
// a gate compares them, because two copies of a file diverge the moment
// someone edits the near one.
//
// The bounded-request helper is a SEPARATE file, composed onto this one only
// for the pages that need it. Every page needs the stand-in; only a page with
// no shared runtime needs its own timeout, and shipping that helper to the
// runtimes would put bytes on every extension page for code none of them call.
//
// ES5 ONLY. The floor is Safari 9.0 / iOS 9.0, whose parser rejects a whole
// file for one arrow function.
//
// The stand-in covers the surface these pages actually use -- status, ok,
// text(), json() -- and nothing else. A partial adapter that is honest about
// its shape is easier to reason about than one that pretends to be the whole
// API and is subtly wrong in the corner somebody eventually reaches.
(function (window) {
  'use strict';

  // Only the STAND-IN is conditional. Everything below it is defined either
  // way: an early return here would leave yurunaRequest undefined on every
  // browser that has a native fetch, which is almost all of them, and the
  // pages that call it would fail on the modern browsers rather than the old
  // one this file exists for.
  if (!window.fetch) {
    window.fetch = function (url, options) {
      options = options || {};
      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open(options.method || 'GET', url, true);
        var headers = options.headers;
        if (headers) {
          for (var k in headers) {
            if (Object.prototype.hasOwnProperty.call(headers, k)) { xhr.setRequestHeader(k, headers[k]); }
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
        // abort() fires onabort, not onerror. Without this the promise of an
        // abandoned request stays pending for the life of the page, and whatever
        // is waiting on it is never told anything.
        xhr.onabort = function () { reject(new Error('The request was given up on.')); };
        // Handed out so a caller can abandon a stalled request. The native path
        // uses AbortController for the same job; this is the only handle that
        // exists when there is no native fetch to attach a signal to.
        if (options.yurunaXhrOut) { options.yurunaXhrOut(xhr); }
        xhr.send(options.body || null);
      });
    };
  }
}(window));
