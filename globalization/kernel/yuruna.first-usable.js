// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Embedded in existing runtimes: no extra request or polling work.
// Only application renderers know when primary content is usable. A parsed
// document, a timer, or a completed request alone cannot establish readiness.
(function (window) {
  'use strict';
  if (window.YurunaFirstUsable) { return; }
  var waiting = {};
  var pending = null;
  var finished = false;
  var marker = window.YurunaFirstUsable = {
    schema: 'yuruna.first-usable/v1',
    contract: 'locale, direction, above-fold text/controls, and primary data or accessible state are ready',
    ready: false, page: '', state: 'pending', locale: '', language: '', dir: '',
    milliseconds: null, clock: 'unavailable'
  };
  function publish() {
    if (finished || !pending) { return; }
    for (var name in waiting) {
      if (Object.prototype.hasOwnProperty.call(waiting, name)) { return; }
    }
    var element = window.document && window.document.documentElement;
    var language = element && element.getAttribute('lang');
    var direction = element && element.getAttribute('dir');
    if (!language || (direction !== 'ltr' && direction !== 'rtl')) { return; }
    var performance = window.performance;
    var milliseconds = null;
    var clock = 'unavailable';
    try {
      if (performance && typeof performance.now === 'function') {
        milliseconds = performance.now();
        if (typeof milliseconds === 'number' && isFinite(milliseconds) && milliseconds >= 0) { clock = 'performance.now'; }
        else { milliseconds = null; }
      }
    } catch (ignore) { milliseconds = null; }
    if (milliseconds === null && performance && performance.timing && performance.timing.navigationStart > 0) {
      var elapsed = new Date().getTime() - performance.timing.navigationStart;
      if (isFinite(elapsed) && elapsed >= 0) { milliseconds = elapsed; clock = 'navigationStart'; }
    }
    marker.page = pending.page;
    marker.state = pending.state;
    marker.language = language;
    marker.locale = window.YurunaI18n ? window.YurunaI18n.locale() : language;
    marker.dir = direction;
    marker.milliseconds = milliseconds;
    marker.clock = clock;
    finished = true;
    marker.ready = true;
  }
  // Opt-in collection times application rendering only; callbacks keep their
  // return values and exceptions when measurement is disabled or unavailable.
  marker.measure = function (page, state, callback) {
    var clock = window.performance;
    if (window.YurunaMeasureRenders !== true || !clock || typeof clock.now !== 'function') {
      return callback();
    }
    var start;
    try { start = clock.now(); } catch (unavailable) { return callback(); }
    if (typeof start !== 'number' || !isFinite(start) || start < 0) { return callback(); }
    var result = callback();
    var elapsed;
    try { elapsed = clock.now() - start; } catch (unavailableEnd) { return result; }
    if (typeof elapsed === 'number' && isFinite(elapsed) && elapsed >= 0) {
      var queue = window.YurunaRenderMeasurements;
      if (!queue || queue.schema !== 'yuruna.render-measurements/v1' || !Array.isArray(queue.samples)) {
        queue = window.YurunaRenderMeasurements = { schema: 'yuruna.render-measurements/v1', samples: [] };
      }
      queue.render = function () { return marker.measure(page, state, callback); };
      var element = window.document && window.document.documentElement;
      var locale = window.YurunaI18n ? window.YurunaI18n.locale() : element && element.getAttribute('lang');
      queue.samples.push({ milliseconds: elapsed, locale: locale || marker.locale, page: page, state: state });
      if (queue.samples.length > 1000) { queue.samples.shift(); }
    }
    return result;
  };
  marker.hold = function (name) { if (!finished) { waiting[name] = true; } };
  marker.release = function (name) { delete waiting[name]; publish(); };
  marker.mark = function (page, state) {
    if (finished || pending || typeof page !== 'string' || !page ||
        !/^(data|empty|error|static)$/.test(state)) { return; }
    pending = { page: page, state: state };
    publish();
  };
}(window));
