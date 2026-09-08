// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Host-centric pool assignment. No innerHTML on data.
(function () {
  var pools = [];
  var targetPoolId = '';
  var goBaseUrl = '';
  // The last answer, kept so a header click re-sorts what is on screen instead
  // of costing a round trip, and so the countdown's reload does not throw the
  // operator's chosen order away.
  var hosts = [];
  var hostnamesVisible = false;
  var sortKey = 'hostId';
  var sortAsc = true;
  // Each host's own account of itself from /api/hosts/facts -- hardware and the
  // two repository columns -- keyed the way rows are: host id when there is
  // one, address otherwise. Fetched at page load and on the header Refresh
  // only: the countdown's periodic reload re-reads the host LIST, but hardware
  // changes on the scale of an upgrade and a repository on the scale of a
  // re-clone, and the fetch fans out to every machine the page lists -- a
  // per-minute poll multiplied by every open tab would hit each one for values
  // that cannot have moved.
  var facts = {};

  // The dashboard collapses control state into remote/onsite. This page shows
  // the wire value instead, because mismatch (wrong token) and skew (clock) need
  // completely different fixes.
  var CONTROL_HINT = {
    ready: 'Holds this lab\'s token; clock agrees.',
    none: 'Never enrolled a lab token -- run Set-LabToken.ps1 on the host.',
    mismatch: 'Holds a DIFFERENT token -- re-enroll against this proxy.',
    skew: 'Token is right but the clock is off -- fix the host clock.',
    unknown: 'Not answered yet, or the proxy holds no token of its own.'
  };

  // The two repository columns are the host's own account of what it runs on,
  // read from the clone it holds (or, when it holds none, from a probe of the
  // url it was configured with). So they answer for EVERY host, pooled or not,
  // and the value is the repository name rather than a status word: an
  // operator reads the table to see which machines are on which repository.
  var REPO_ACCESS_LABEL = { frameworkAccess: 'framework', projectAccess: 'project' };
  // Where each column's repository lives, reported beside the name it belongs to.
  var REPO_URL_KEY = { frameworkAccess: 'frameworkUrl', projectAccess: 'projectUrl' };
  // The English phrase this column used to print. It is kept only to read a
  // host too old to send a state -- see isRepoDenied -- and is never rendered:
  // what a reader sees comes from the catalog.
  var LEGACY_NO_ACCESS = 'No access';

  function t(key, args) { return window.YurunaI18n.t(key, args || null); }
  // The condition behind each column, reported as a stable token beside the
  // name. The column's own value carries a repository name in one case and the
  // words "No access" in another, so asking whether a host is denied used to
  // mean comparing that English phrase -- which made the phrase a contract
  // between the host's PowerShell, the relay and this page.
  var REPO_STATE_KEY = { frameworkAccess: 'frameworkAccessState', projectAccess: 'projectAccessState' };

  // A host older than the state field reports none, and its phrase is still
  // read. Once a state is present it is the whole answer, so the phrase can be
  // reworded or translated without this test noticing.
  function isRepoDenied(h, key, value) {
    var state = h[REPO_STATE_KEY[key]];
    if (state) { return state === 'denied'; }
    return value === LEGACY_NO_ACCESS;
  }

  // The pool's separate question -- can this MEMBER read what its pool assigned
  // -- is answered in the host's registration record, and denied is the one
  // value that needs an operator. It rides the project cell's tooltip: the
  // column itself shows what the host holds, which is a different fact.
  // Keyed by the state the host reported, so the words are chosen by a value
  // rather than matched from one.
  var POOL_ACCESS_KEY = {
    denied: 'pool.pool_project_denied',
    unreachable: 'pool.pool_project_unreachable'
  };

  function poolAccessHint(state) {
    var key = state ? POOL_ACCESS_KEY[state] : null;
    return key ? t(key) : '';
  }

  // Raw value for a repository column, or '' when the host did not report one.
  function accessValue(h, key) {
    var f = facts[factKey(h)];
    if (!f || !f.ok) { return ''; }
    return String(f[key] || '');
  }

  // What a repository column's cell may become an href to, or '' for none. The
  // host normalizes the value; this is the second of two checks, and it is here
  // because the string reaches an href and arrives from a machine the page does
  // not control -- a javascript: or data: url must never get there on the
  // strength of the far end having been well behaved.
  //
  // file: is allowed alongside http(s): a host whose repository is a local copy
  // is a legitimate lab setup, and the operator asked which one it is. Most
  // browsers refuse to NAVIGATE there from a served page, but the link still
  // names the location and copies.
  function accessUrl(h, key) {
    var f = facts[factKey(h)];
    if (!f || !f.ok) { return ''; }
    var s = String(f[REPO_URL_KEY[key]] || '').trim();
    if (!s) { return ''; }
    // Parsed with an anchor rather than `new URL`, which the browser baseline
    // does not carry: assigning to a detached anchor resolves the value exactly
    // as the browser would before following it, which is the whole point of
    // reading the scheme back off it.
    try {
      var a = document.createElement('a');
      a.href = s;
      return (a.protocol === 'http:' || a.protocol === 'https:' || a.protocol === 'file:') ? s : '';
    } catch (e) {
      return '';
    }
  }

  // The name, linked to the repository it names. An operator reading this table
  // is asking whether a machine is on the repository they think it is, and the
  // answer is one click from the cell rather than a url to retype. A host that
  // reported no location (an older build, a remote nothing can be addressed at)
  // keeps the plain text: the cell never links nowhere.
  function repoEl(url, attrs, text) {
    if (!url) { return Y.el('span', attrs, text); }
    // Y.linkTo, not an href through Y.el: accessUrl above has already decided
    // this value is http(s) or file, and file: is not in Y.el's default set --
    // it is opted into here, by the one column that means it.
    var linked = Object.assign({}, attrs, { target: '_blank', rel: 'noopener' });
    return Y.linkTo(url, ['file:'], linked, text);
  }

  function accessCell(h, key, error) {
    var what = REPO_ACCESS_LABEL[key];
    var value = accessValue(h, key);
    var url = accessUrl(h, key);
    // The url ends the tooltip rather than sitting inside it: the cell shows a
    // name, and where that name came from is what an operator checks before
    // following the link.
    var where = url ? ' ' + Y.bidiIsolate(url) : '';
    var poolHint = key === 'projectAccess' ? poolAccessHint(h.access) : '';
    if (isRepoDenied(h, key, value)) {
      // Linked to the url it could NOT read, which is the one an operator
      // checks first: a url naming the wrong repository looks exactly like a
      // credential that is missing one until someone follows it.
      // Each description is a whole sentence chosen by which repository this
      // is, not one assembled around the word for it. A sentence built by
      // dropping a noun into a slot cannot be reordered by a translator, and
      // several languages need to reorder it.
      return repoEl(url, {
        title: t('pool.repo_denied_detail', { repo: what }) + where
      }, Y.el('strong', { text: t('pool.repo_no_access') }));
    }
    if (value) {
      return repoEl(url, {
        title: (poolHint ? poolHint + ' ' : '') + t('pool.repo_held_detail', { repo: what }) + where
      }, Y.bidiIsolate(value));
    }
    return Y.el('span', {
      class: 'muted', text: '--',
      title: poolHint || (error ? Y.bidiIsolate(error) : '') ||
        t('pool.repo_unconfigured_detail', { repo: what })
    });
  }

  // Two different blanks, and they need different answers from the operator:
  // withheld until this browser is unlocked, or a host that never reported one
  // (it has no address the pool can read a registration record from).
  function hostnameCell(name) {
    if (name) { return Y.el('span', { text: name }); }
    return Y.el('span', {
      class: 'muted', text: '--',
      title: hostnamesVisible
        ? 'This host has not reported a name.'
        : 'Unlock with the Lab token to see hostnames.'
    });
  }

  function typeCell(type) {
    if (!type) { return Y.el('span', { class: 'muted', text: '--' }); }
    return Y.el('span', { text: type });
  }

  // Which raw facts field backs each hardware column, for both cells and sort.
  var FACT_KEY = {
    memory: 'memoryBytes',
    cores: 'cores',
    storageTotal: 'storageTotalBytes',
    storageFree: 'storageFreeBytes'
  };

  // Bytes as an integer in the largest unit that keeps it at or under 1024:
  // 32 GiB RAM reads "32 GB", a 2 TB array reads "2 TB" rather than "2048 GB".
  var BYTE_UNITS = [['MB', 1048576], ['GB', 1073741824], ['TB', 1099511627776]];
  function fmtBytes(n) {
    if (!(n > 0)) { return null; }
    for (var i = 0; i < BYTE_UNITS.length; i++) {
      var name = BYTE_UNITS[i][0];
      var v = Math.round(n / BYTE_UNITS[i][1]);
      if (v <= 1024 || name === 'TB') { return v + ' ' + name; }
    }
    return null;
  }

  // One blank for every way a fact can be missing (host silent, older host
  // build without the route, fan-out still unfetched); the title says which.
  // Takes a formatted string or a raw number (the Cores column).
  function factCell(value, error) {
    if (value !== null && value !== undefined && value !== '') { return Y.el('span', { text: String(value) }); }
    return Y.el('span', {
      class: 'muted', text: '--',
      title: error ? Y.bidiIsolate(error) : 'This host has not reported hardware facts.'
    });
  }

  // The identity a row's facts arrive under. A discovered host that could not
  // name itself is known by the address it answered at, and the endpoint keys
  // it the same way -- so both halves agree without either knowing whether the
  // row came from the aggregator or from a scan.
  function factKey(h) {
    return h.hostId || h.address || '';
  }

  // Raw number for a fact, or null when the host has none -- null is what the
  // sort ranks last, same as the string columns' blanks.
  function factValue(h, key) {
    var f = facts[factKey(h)];
    if (!f || !f.ok) { return null; }
    var v = Number(f[FACT_KEY[key]]);
    return v > 0 ? v : null;
  }

  // Hardware columns sort on their raw numbers; every other column is a string
  // on the wire, so one comparison serves them all -- lowercased, because a
  // hostname's capitalization is not a sort order anyone means to ask for.
  //
  // A discovered host that could not name itself has no id to sort on, so it
  // sorts on the address it answered at -- otherwise every such row would herd
  // to one end of the table as a blank, away from the machines beside it.
  function sortValue(h, key) {
    if (FACT_KEY[key]) { return factValue(h, key); }
    if (REPO_ACCESS_LABEL[key]) { return accessValue(h, key).toLowerCase(); }
    if (key === 'hostId') { return String(h.hostId || h.address || '').toLowerCase(); }
    return String(h[key] || '').toLowerCase();
  }

  function sorted(rows) {
    return rows.slice().sort(function (a, b) {
      var av = sortValue(a, sortKey);
      var bv = sortValue(b, sortKey);
      var cmp = 0;
      if (av !== bv) {
        // A row with no value ranks last ascending: sorting on a column is a
        // way of reading the rows that HAVE one, and this page is full of
        // blanks -- a withheld hostname, a host the pool cannot reach, a
        // hardware fact (null) from a host that never answered.
        if (av === '' || av === null) { cmp = 1; }
        else if (bv === '' || bv === null) { cmp = -1; }
        else { cmp = av < bv ? -1 : 1; }
      }
      if (!sortAsc) { cmp = -cmp; }
      if (cmp !== 0) { return cmp; }
      // Host ids are unique, so tying rows land in ONE order for a given column
      // rather than reshuffling under the operator on the next refresh.
      var ai = sortValue(a, 'hostId');
      var bi = sortValue(b, 'hostId');
      return ai < bi ? -1 : (ai > bi ? 1 : 0);
    });
  }

  // The first column for a host this service found by scanning rather than one
  // the aggregator reported.
  //
  // The id is TEXT here, not the usual link. A pool host's id links through the
  // aggregator's /go/host, which resolves the host's current address from what
  // it has registered -- and a discovered host is by definition one that
  // registered nothing, so that link can only ever land on a "no such host".
  // The address is the way in instead: it is where this service just got an
  // answer, so it is the one address known to work.
  function hostCell(h) {
    if (!h.discovered) { return Y.hostLink(h.hostId, h.pool, goBaseUrl); }
    var box = Y.el('span', { class: 'discovered-host' });
    if (h.hostId) box.appendChild(Y.el('span', { class: 'mono', text: Y.shortHost(h.hostId), title: Y.guid(h.hostId) }));
    var seen = h.lastSeen ? ', last seen ' + window.YurunaI18n.fmtLocal(new Date(h.lastSeen)) : '';
    if (h.baseUrl) {
      box.appendChild(Y.el('a', {
        class: 'mono', href: h.baseUrl, target: '_blank', rel: 'noopener',
        title: 'Open this host\'s own status page at ' + Y.bidiIsolate(h.baseUrl) +
          ' (found by a network scan' + seen + ')'
      }, Y.bidiIsolate(h.address)));
    } else {
      box.appendChild(Y.el('span', { class: 'mono', text: h.address, title: 'Found by a network scan' + seen }));
    }
    box.appendChild(Y.el('span', { class: 'badge discovered', text: 'discovered', title: 'Found by scanning the network; it belongs to no pool and has not registered with the aggregator.' }));
    return box;
  }

  function rowEl(h, n) {
    var sel = Y.el('select', {
      'aria-label': 'Pool for host ' + Y.bidiIsolate(h.hostId || h.address)
    });
    sel.appendChild(Y.el('option', { value: '', text: '(none)' }));
    for (var i = 0; i < pools.length; i++) {
      var p = pools[i];
      var o = Y.el('option', {
        value: p,
        text: Y.bidiIsolate(p) + (p === targetPoolId ? ' -- auto-enrollment target' : '')
      });
      if (p === h.pool) { o.selected = true; }
      sel.appendChild(o);
    }
    Y.onSelectCommit(sel, function () {
      var to = sel.value;
      var label = to || '(none)';
      // (none) also records an exclusion, or the sweep would undo this within a
      // minute and the UI would look broken. Say so, rather than surprise them.
      var extra = to ? '' : '\n\nIt will also be excluded from auto-enrollment, so the sweep will not add it back.';
      if (!window.confirm('Move host ' + Y.bidiIsolate(Y.guid(h.hostId)) + ' to ' +
          Y.bidiIsolate(label) + '?' + extra)) {
        sel.value = h.pool || '';
        return;
      }
      Y.clearNotice();
      Y.mutate('/api/pool/move-host', { method: 'POST', body: { hostId: h.hostId, poolId: to } }).then(function () {
        // Beside the picker as well as in the banner: on a twelve-column table
        // at high zoom the banner at the top of <main> is not on screen with
        // the row that produced it.
        Y.rowFeedback(sel.closest('tr'), 'ok', 'Moved to ' + Y.bidiIsolate(label) + '.');
        return load();
      }, function (e) {
        sel.value = h.pool || '';
        Y.notice('error', e.message);
        Y.rowFeedback(sel.closest('tr'), 'error', 'Move failed: ' + Y.bidiIsolate(e.message));
      });
    });

    // Pool membership is recorded against a host id, so a discovered host that
    // has not reported one cannot be put in a pool yet -- the picker says so
    // rather than failing on the far side of a confirm dialog.
    if (!h.hostId) {
      sel.disabled = true;
      sel.title = 'This host has not reported an id, so it cannot be assigned to a pool yet.';
    }

    var control = Y.el('span', { text: h.control, title: CONTROL_HINT[h.control] || '' });
    var f = facts[factKey(h)];
    var factErr = f && !f.ok ? (f.error || '') : '';
    return Y.el('tr', {}, [
      Y.numCell(n),
      Y.el('td', {}, [hostCell(h)]),
      Y.el('td', {}, [hostnameCell(h.hostname)]),
      Y.el('td', { class: 'host-type' }, [typeCell(h.type)]),
      Y.el('td', {}, [factCell(fmtBytes(factValue(h, 'memory')), factErr)]),
      Y.el('td', {}, [factCell(factValue(h, 'cores'), factErr)]),
      Y.el('td', {}, [factCell(fmtBytes(factValue(h, 'storageTotal')), factErr)]),
      Y.el('td', {}, [factCell(fmtBytes(factValue(h, 'storageFree')), factErr)]),
      Y.el('td', {}, [control]),
      Y.el('td', {}, [accessCell(h, 'frameworkAccess', factErr)]),
      Y.el('td', {}, [accessCell(h, 'projectAccess', factErr)]),
      Y.el('td', {}, [sel])
    ]);
  }

  function render() {
    var body = document.getElementById('host-rows');
    if (Y.holdRepaint(body, render)) { return; }
    body.textContent = '';
    // The counter numbers the position on screen, not the host in it, so it
    // runs 1..n down the page whichever column the table is sorted by.
    var ordered = sorted(hosts);
    for (var i = 0; i < ordered.length; i++) { body.appendChild(rowEl(ordered[i], i + 1)); }
    var unlock = document.getElementById('show-hostnames');
    if (unlock) { unlock.hidden = hostnamesVisible; }
  }

  // The header cells carry the sort key; the buttons inside them are what the
  // keyboard and the screen reader act on, and aria-sort on the cell is what
  // announces the result. Clicking the sorted column reverses it.
  function initSort() {
    var ths = document.querySelectorAll('th[data-sort]');
    for (var i = 0; i < ths.length; i++) {
      // Wired through a call rather than from the loop body, so each handler
      // closes over ITS header cell instead of the last one in the row.
      (function (th) {
        var btn = th.querySelector('button');
        if (!btn) { return; }
        btn.addEventListener('click', function () {
          var key = th.getAttribute('data-sort');
          if (key === sortKey) { sortAsc = !sortAsc; }
          else { sortKey = key; sortAsc = true; }
          markSorted();
          render();
        });
      }(ths[i]));
    }
    markSorted();
  }

  function markSorted() {
    var ths = document.querySelectorAll('th[data-sort]');
    for (var i = 0; i < ths.length; i++) {
      if (ths[i].getAttribute('data-sort') === sortKey) {
        ths[i].setAttribute('aria-sort', sortAsc ? 'ascending' : 'descending');
      } else {
        ths[i].removeAttribute('aria-sort');
      }
    }
  }

  // quiet marks a read the operator did not ask for (the countdown's), which
  // keeps the rows it is refreshing on screen and signals in the footer. Every
  // other read replaces the table, so it says so: this one fans out to every
  // host in the lab and a silent machine holds it up for seconds.
  function load(opts) {
    var quiet = !!(opts && opts.quiet);
    var done = quiet ? function () { } : Y.busy(document.getElementById('host-rows'), 'Loading hosts...');
    chrome.busy(true);
    var finish = function () { done(); chrome.busy(false); };
    // The hostname column turns on a session, and arriving from the dashboard
    // brings one in the URL fragment -- so wait for that exchange to settle
    // rather than fetching first and rendering a locked table to an operator
    // who is, a moment later, unlocked.
    return Y.ready().then(function () {
      // Y.hostInfo is memoized and non-rejecting, so this is one read for the
      // life of the page and an aggregator this daemon does not know about just
      // means unlinked ids.
      return Promise.all([Y.api('/api/hosts'), Y.hostInfo()]);
    }).then(function (both) {
      var d = both[0];
      chrome.markLoaded();
      goBaseUrl = both[1].goBaseUrl || '';
      pools = d.pools || [];
      targetPoolId = d.targetPoolId || '';
      hosts = d.hosts || [];
      hostnamesVisible = !!d.hostnamesVisible;
      render();
      if (d.statusError) {
        Y.notice('warn', 'Aggregator unavailable (' + Y.bidiIsolate(d.statusError) + '); control state is unknown. Moving hosts still works.');
      } else {
        Y.clearNotice();
      }
    }, function (e) {
      Y.notice('error', e.message);
    }).then(finish, finish);
  }

  // Silent on failure by design: the table is fully usable without hardware
  // facts, and the columns' em-dash tooltips already say a host did not report.
  // It shows in the footer rather than over the table for the same reason: the
  // rows are already readable while these columns fill in.
  function loadFacts() {
    chrome.busy(true);
    var idle = function () { chrome.busy(false); };
    return Y.api('/api/hosts/facts').then(function (d) {
      facts = d.hosts || {};
      // Only a repaint of rows that exist. On first load these two reads race,
      // and painting an empty table here would take down the wait indicator the
      // host read is still under -- leaving a blank page mid-fetch.
      if (hosts.length) { render(); }
    }, function () {
      // Facts keep their last value: the table is fully usable without them.
    }).then(idle, idle);
  }

  document.getElementById('refresh').addEventListener('click', function () {
    load();
    loadFacts();
  });
  // The only control on this page that asks for the lab token up front. Every
  // other page prompts at the moment a change is attempted, but the hostname is
  // a READ that needs a session, so without this an operator who wants the
  // column has nothing to click.
  document.getElementById('show-hostnames').addEventListener('click', function () {
    Y.unlock().then(function (ok) { if (ok) { load(); } });
  });
  initSort();
  // Header version + host id and the footer bar; its countdown re-reads the host
  // list rather than reloading, so a pending pool choice in a row survives. The
  // countdown deliberately does NOT re-fetch hardware facts (see `facts`).
  var chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });
  load();
  loadFacts();
})();
