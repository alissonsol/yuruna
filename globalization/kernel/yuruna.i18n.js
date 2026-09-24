// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The catalog kernel: resolve a locale, look a message up, format its
// arguments. This file is the single source. tools/Invoke-CatalogEmbed.ps1
// copies it, byte for byte, into every browser runtime that needs it, so a
// page never spends a request on it and the two runtimes cannot drift apart.
// Edit here and re-run that tool; an edit made in a copy is overwritten and
// the drift gate fails first.
//
// Nothing here parses a message. The compiler already broke every message into
// the pieces this walks, which is what lets a label be rendered per row without
// the cost showing up on the page. Nothing here reads Intl either: the ICU data
// behind a runtime differs by engine and shifts between releases, so separators
// and plural rules come from the compiled locale data and are the same
// everywhere.
(function (root) {
  'use strict';

  var Y = root.YurunaI18n = root.YurunaI18n || {};
  // The compiled tables register themselves here as they load, keyed by tag
  // and then by domain. The default locale is compiled into the runtime, so
  // this is never empty and a release fallback is always resident.
  var catalogs = root.YurunaCatalog = root.YurunaCatalog || {};
  var localeData = root.YurunaLocaleData = root.YurunaLocaleData || {};
  // Generated separately from localeData. Planned locales have formatting
  // data while translators work, but are not selectable. Pseudo locales are
  // enabled here because the server independently gates whether a page may
  // declare/load one for an explicit test run.
  var enabledLocales = root.YurunaEnabledLocales || {};

  var DEFAULT_TAG = 'en-US';
  var current = DEFAULT_TAG;
  var initialized = false;
  var pageContext = null;
  var reported = {};

  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  function freezeContext(value) {
    // The guard is for deliberately capability-stripped test hosts: the
    // context is still private there and callers receive no setter for its
    // fields.
    if (Object.freeze) { return Object.freeze(value); }
    return value;
  }

  function validSource(value) {
    return value === 'config' || value === 'user' || value === 'http' ||
           value === 'process' || value === 'default';
  }

  function newPageContext(requested, resolved, source) {
    var provenance = root.YurunaCatalogProvenance || {};
    return freezeContext({
      requestedTag: requested || resolved,
      resolvedTag: resolved,
      direction: dataFor(resolved).direction || 'ltr',
      source: validSource(source) ? source : 'default',
      // Browser wall clocks deliberately use the reader's local zone. That
      // policy is explicit here rather than hidden inside Date getters.
      timeZone: 'local',
      catalogVersion: String(provenance.version || ''),
      catalogHash: String(provenance.hash || '')
    });
  }

  // One diagnostic per key per locale per page. A missing key inside a table
  // render would otherwise log once per row, which buries the first report in
  // its own repetitions.
  function reportOnce(what) {
    if (has(reported, what)) { return; }
    reported[what] = true;
    if (root.console && root.console.warn) { root.console.warn('Yuruna i18n: ' + what); }
  }

  function dataFor(tag) {
    if (has(localeData, tag)) { return localeData[tag]; }
    return localeData[DEFAULT_TAG] || { group: ',', decimal: '.', groupSize: 3, plural: 'one-if-1', direction: 'ltr' };
  }

  // The count's category, by the rule the manifest pinned for this locale.
  // A locale whose rule is not pinned falls back to the default's rather than
  // throwing: this runs inside a render, and a page that throws mid-render
  // leaves a half-built DOM the reader cannot act on. The compiler is what
  // keeps an unpinned locale from ever being marked supported.
  function pluralCategory(tag, count) {
    var rule = dataFor(tag).plural;
    if (!rule) {
      reportOnce('no pinned plural rule for ' + tag);
      rule = dataFor(DEFAULT_TAG).plural;
    }
    switch (rule) {
      case 'one-if-1': return count === 1 ? 'one' : 'other';
      case 'pt-cardinal-cldr46':
        count = Math.abs(count);
        if (Math.floor(count) <= 1) { return 'one'; }
        if (count > 0 && count % 1000000 === 0) { return 'many'; }
        return 'other';
      default:
        reportOnce('unknown plural rule ' + rule);
        return 'other';
    }
  }

  // Group a digit string from the right. toLocaleString is not usable here:
  // its separators come from the engine's own ICU data, which differs between
  // browsers and between releases, so the same number would be written one way
  // on the page and another by the PowerShell and Go sides that have to agree
  // with it byte for byte.
  function groupDigits(digits, sep, size) {
    if (!sep || size <= 0 || digits.length <= size) { return digits; }
    var out = '';
    var count = 0;
    for (var i = digits.length - 1; i >= 0; i--) {
      out = digits.charAt(i) + out;
      count++;
      if (count % size === 0 && i > 0) { out = sep + out; }
    }
    return out;
  }

  function formatNumber(value, tag, decimals) {
    var d = dataFor(tag);
    var n = Number(value);
    if (!isFinite(n)) { return ''; }
    var negative = n < 0;
    var text = Math.abs(n).toFixed(decimals);
    var parts = text.split('.');
    var whole = groupDigits(parts[0], d.group, d.groupSize || 3);
    var out = parts.length > 1 ? whole + d.decimal + parts[1] : whole;
    return negative ? '-' + out : out;
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function formatArgument(value, type, tag) {
    if (value === null || value === undefined) { return ''; }
    switch (type) {
      case 'integer': return formatNumber(value, tag, 0);
      case 'decimal': return formatNumber(value, tag, 2);
      case 'duration':
        // Floor, never round. 5400 seconds is an hour and a half, and a rule
        // that rounded would report it as "2h 30m" -- longer than the time
        // that actually passed, in the part of the string a reader is least
        // likely to question.
        var total = Math.floor(Number(value));
        if (!isFinite(total) || total < 0) { return ''; }
        var h = Math.floor(total / 3600);
        var m = Math.floor((total % 3600) / 60);
        var s = total % 60;
        if (h >= 1) { return h + 'h ' + m + 'm'; }
        if (m >= 1) { return m + 'm ' + s + 's'; }
        return s + 's';
      case 'datetime':
        var when = (value instanceof Date) ? value : new Date(value);
        if (isNaN(when.getTime())) { return ''; }
        return when.getUTCFullYear() + '-' + pad2(when.getUTCMonth() + 1) + '-' + pad2(when.getUTCDate()) +
               ' ' + pad2(when.getUTCHours()) + ':' + pad2(when.getUTCMinutes()) + ':' + pad2(when.getUTCSeconds()) + ' UTC';
      default:
        // An external value is placed as given and never parsed back into
        // state. Escaping belongs to the caller, which knows whether it is
        // writing textContent or an attribute; this returns a string.
        return String(value);
    }
  }

  function renderSegments(segments, args, tag) {
    if (typeof segments === 'string') { return segments; }
    if (!segments || typeof segments.length !== 'number') { return ''; }
    var out = '';
    for (var i = 0; i < segments.length; i++) {
      var piece = segments[i];
      if (typeof piece === 'string') { out += piece; continue; }
      if (piece && has(piece, 'arg')) {
        var value = (args && has(args, piece.arg)) ? args[piece.arg] : null;
        out += formatArgument(value, piece.type, tag);
        continue;
      }
      out += String(piece);
    }
    return out;
  }

  function lookup(tag, key) {
    var domain = key.split('.')[0];
    var byLocale = catalogs[tag];
    if (byLocale && byLocale[domain] && has(byLocale[domain], key)) { return byLocale[domain][key]; }
    return null;
  }

  // The rendered message, or -- when nothing has this key -- the key itself.
  // A supported catalog is complete by definition and the compiler fails on a
  // gap, so reaching the fallback means a page asked for something no catalog
  // declares. Showing the key keeps the surface readable and puts the mistake
  // where someone will see it; blank text would not.
  function translate(key, args, tag) {
    var use = tag || current;
    var entry = lookup(use, key);
    if (entry === null && use !== DEFAULT_TAG) {
      reportOnce('key ' + key + ' missing for ' + use);
      entry = lookup(DEFAULT_TAG, key);
      use = DEFAULT_TAG;
    }
    if (entry === null) {
      reportOnce('key ' + key + ' is in no catalog');
      return key;
    }
    if (typeof entry === 'string') { return entry; }

    if (entry && has(entry, 'kind')) {
      var selector = entry.selector;
      var chosen = null;
      if (entry.kind === 'plural') {
        var count = (args && has(args, selector)) ? Number(args[selector]) : 0;
        chosen = entry.variants[pluralCategory(use, count)];
      } else {
        var value = (args && has(args, selector)) ? String(args[selector]) : '';
        chosen = has(entry.variants, value) ? entry.variants[value] : null;
      }
      if (chosen === null || chosen === undefined) { chosen = entry.variants.other; }
      if (chosen === null || chosen === undefined) { return key; }
      return renderSegments(chosen, args, use);
    }

    return renderSegments(entry, args, use);
  }

  // Which of the locales this page carries answers for a tag. Only an exact
  // match or a declared alias counts: a page that answered pt-AO with pt-BR
  // would be serving a dialect nobody reviewed, and the reader has no way to
  // tell the difference until the wording is wrong.
  function resolve(tag) {
    if (!tag) { return DEFAULT_TAG; }
    var canonical = String(tag).replace(/_/g, '-').replace(/^\s+|\s+$/g, '');
    if (!/^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(canonical)) { return DEFAULT_TAG; }
    var parts = canonical.split('-');
    var normal = parts[0].toLowerCase();
    for (var i = 1; i < parts.length; i++) {
      var p = parts[i];
      if (p.length === 4) { normal += '-' + p.charAt(0).toUpperCase() + p.slice(1).toLowerCase(); }
      else if (p.length === 2) { normal += '-' + p.toUpperCase(); }
      else { normal += '-' + p.toLowerCase(); }
    }
    // A non-default catalog may load immediately after the shared runtime.
    // Selection therefore follows generated locale authority, not the timing
    // of script registration; t() can use the table as soon as it arrives.
    var enabled = enabledLocales[normal.toLowerCase()];
    if (enabled) { return enabled === true ? normal : enabled; }
    var aliases = root.YurunaLocaleAliases || {};
    var aliased = aliases[normal.toLowerCase()];
    enabled = aliased ? enabledLocales[String(aliased).toLowerCase()] : '';
    if (enabled) { return enabled === true ? aliased : enabled; }
    return DEFAULT_TAG;
  }

  // The page's language is decided by the server and written into <html lang>,
  // so it is already correct at first paint and nothing here can produce a
  // flash of the wrong language.
  function init(doc, decision) {
    if (initialized) { return pageContext.resolvedTag; }
    var el = doc && doc.documentElement;
    var declared = el ? (el.getAttribute('lang') || '') : '';
    current = resolve(declared);
    var requested = decision && decision.requestedTag;
    var source = decision && decision.source;
    if (!requested && el) { requested = el.getAttribute('data-yuruna-requested-language') || declared; }
    if (!source && el) { source = el.getAttribute('data-yuruna-locale-source') || 'default'; }
    pageContext = newPageContext(requested, current, source);
    initialized = true;
    if (el && !el.getAttribute('dir')) { el.setAttribute('dir', pageContext.direction); }
    return current;
  }

  // A wall-clock stamp in the reader's own zone, in a shape that does not
  // change with the reader's device.
  //
  // toLocaleString would be the obvious call and is the wrong one: the shape it
  // produces comes from the engine's ICU data, so the same instant is written
  // one way on one browser and another way on the next, and neither matches
  // what the PowerShell and Go sides emit for it. The shape here is fixed for
  // everyone; only the zone is local, which is what makes a "last seen"
  // readable.
  function formatLocal(value) {
    var when = (value instanceof Date) ? value : new Date(value);
    if (isNaN(when.getTime())) { return ''; }
    return when.getFullYear() + '-' + pad2(when.getMonth() + 1) + '-' + pad2(when.getDate()) +
           ' ' + pad2(when.getHours()) + ':' + pad2(when.getMinutes());
  }

  // The time alone, for a ticker that says when the page last refreshed. The
  // date would be noise there and the same reasoning applies to the shape.
  function formatLocalTime(value) {
    var when = (value instanceof Date) ? value : new Date(value);
    if (isNaN(when.getTime())) { return ''; }
    return pad2(when.getHours()) + ':' + pad2(when.getMinutes()) + ':' + pad2(when.getSeconds());
  }

  Y.fmtLocal = formatLocal;
  Y.fmtLocalTime = formatLocalTime;
  Y.t = translate;
  Y.init = init;
  Y.resolve = resolve;
  Y.formatArgument = formatArgument;
  Y.formatNumber = formatNumber;
  Y.pluralCategory = pluralCategory;
  Y.locale = function () { return current; };
  // Kept for the older fixture harness. Once init has sealed the page's
  // server-owned decision, a local caller cannot switch half the page into a
  // different language.
  Y.setLocale = function (tag) {
    if (initialized) { return current; }
    current = resolve(tag);
    pageContext = newPageContext(tag, current, 'user');
    return current;
  };
  Y.context = function () {
    if (!pageContext) { pageContext = newPageContext(DEFAULT_TAG, DEFAULT_TAG, 'default'); }
    return pageContext;
  };
  Y.direction = function () { return Y.context().direction; };
}(typeof window !== 'undefined' ? window : this));
