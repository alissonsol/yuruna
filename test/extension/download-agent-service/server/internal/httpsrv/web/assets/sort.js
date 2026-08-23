// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Ordering rules for the Download pool table, kept apart from the DOM wiring so
// every comparator reads in one screen. Sorting is comparison-only: it never
// touches the document.
(function () {
  var S = {};

  // The columns a header can sort by, in table order. Actions is absent: it
  // holds controls, not a value, and ordering by it would mean nothing.
  S.columns = ['state', 'image', 'artifact', 'size', 'verified', 'checksum', 'source'];

  // Severity, not the alphabet: an operator sorting by state is looking for the
  // row that needs them, and "failed" is that row.
  // `unavailable` outranks `absent`: an absent row fills itself on the next
  // scan, an unavailable one waits for the operator to install something.
  S.stateRank = { failed: 0, downloading: 1, unavailable: 2, absent: 3, stale: 4, fresh: 5 };
  // A state this table does not rank -- `deleting`, or one a later agent adds --
  // sorts after every ranked one instead of silently borrowing a neighbor's
  // urgency, and stays where the identity tiebreak puts it.
  var UNRANKED = 90;

  // Never verified is the oldest thing there is, so those rows gather at the
  // same end of the timestamp order whichever direction is active.
  var NEVER_VERIFIED = -Infinity;

  S.isColumn = function (col) { return S.columns.indexOf(col) >= 0; };

  function str(v) { return (v === null || v === undefined) ? '' : String(v); }

  // displayText mirrors what the cell actually shows, so the order matches what
  // the operator is reading rather than a field they cannot see.
  function displayText(img, col) {
    switch (col) {
      case 'image': return [img.imageKey, img.hostType, img.arch, img.variant].map(str).join(' ');
      case 'artifact': return [img.upstreamFilename, img.generation].map(str).join(' ');
      case 'checksum': return str(img.checksumVerdict);
      case 'source': return str(img.sourceUrl);
      default: return '';
    }
  }

  function verifiedAt(img) {
    if (!img.lastVerifiedAt) return NEVER_VERIFIED;
    var t = Date.parse(img.lastVerifiedAt);
    return isNaN(t) ? NEVER_VERIFIED : t;
  }

  function sizeOf(img) {
    // Current generation only, and as a number: the cell renders "9 GiB" and
    // "12 GiB", which as text would order the larger image first.
    var n = Number(img.currentBytes);
    return isFinite(n) ? n : 0;
  }

  function stateRank(img) {
    // hasOwnProperty, not a plain lookup: a state named like something on
    // Object.prototype would otherwise rank as an inherited member and hand the
    // comparator a value that is not a number at all.
    var name = str(img.state).toLowerCase();
    return Object.prototype.hasOwnProperty.call(S.stateRank, name) ? S.stateRank[name] : UNRANKED;
  }

  // key is the value a column sorts on: a number where the display is derived
  // from one, the displayed text otherwise.
  S.key = function (img, col) {
    switch (col) {
      case 'state': return stateRank(img);
      case 'size': return sizeOf(img);
      case 'verified': return verifiedAt(img);
      default: return displayText(img, col);
    }
  };

  // identity is the tiebreak. Every row in the pool has a distinct one, so a
  // column full of equal values still yields one fixed order -- without it rows
  // would swap places under the cursor on every poll.
  S.identity = function (img) {
    return [img.hostType, img.imageKey, img.arch, img.variant].map(str).join('\u0000');
  };

  function cmpNum(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  function cmpText(a, b) {
    var x = a.toLowerCase(), y = b.toLowerCase();
    return x < y ? -1 : x > y ? 1 : 0;
  }

  // compare builds the comparator for one column and direction (1 ascending,
  // -1 descending). The direction applies to the column only; the identity
  // tiebreak always ascends, so reversing a column reverses what the operator
  // clicked on and nothing else.
  S.compare = function (col, dir) {
    var d = dir < 0 ? -1 : 1;
    return function (a, b) {
      var ka = S.key(a, col), kb = S.key(b, col);
      var c = (typeof ka === 'number') ? cmpNum(ka, kb) : cmpText(ka, kb);
      return c !== 0 ? c * d : cmpText(S.identity(a), S.identity(b));
    };
  };

  // sort returns a new array; the caller's catalog stays in the order the API
  // sent it, which is what the table falls back to when no column is chosen.
  S.sort = function (rows, col, dir) {
    if (!S.isColumn(col)) return rows.slice();
    return rows.slice().sort(S.compare(col, dir));
  };

  window.YSort = S;
})();
