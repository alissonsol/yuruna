// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Host-centric pool assignment. No innerHTML on data.
(function () {
  let pools = [];
  let targetPoolId = '';
  let goBaseUrl = '';
  // The last answer, kept so a header click re-sorts what is on screen instead
  // of costing a round trip, and so the countdown's reload does not throw the
  // operator's chosen order away.
  let hosts = [];
  let hostnamesVisible = false;
  let sortKey = 'hostId';
  let sortAsc = true;
  // Each host's own account of itself from /api/hosts/facts -- hardware and the
  // two repository columns -- keyed the way rows are: host id when there is
  // one, address otherwise. Fetched at page load and on the header Refresh
  // only: the countdown's periodic reload re-reads the host LIST, but hardware
  // changes on the scale of an upgrade and a repository on the scale of a
  // re-clone, and the fetch fans out to every machine the page lists -- a
  // per-minute poll multiplied by every open tab would hit each one for values
  // that cannot have moved.
  let facts = {};

  // The dashboard collapses control state into remote/onsite. This page shows
  // the wire value instead, because mismatch (wrong token) and skew (clock) need
  // completely different fixes.
  const CONTROL_HINT = {
    ready: 'Holds this lab’s token; clock agrees.',
    none: 'Never enrolled a lab token — run Set-LabToken.ps1 on the host.',
    mismatch: 'Holds a DIFFERENT token — re-enrol against this proxy.',
    skew: 'Token is right but the clock is off — fix the host clock.',
    unknown: 'Not answered yet, or the proxy holds no token of its own.'
  };

  // The GUID-dashed presentation the dashboard uses for the opaque id. The
  // table shows the short id, but a confirm prompt is where an operator commits
  // to moving a machine: it names the host in full, and dashes are what makes
  // 32 hex characters checkable against another screen.
  function guid(hostId) {
    const h = String(hostId);
    if (h.length !== 32) return h;
    return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join('-');
  }

  // The two repository columns are the host's own account of what it runs on,
  // read from the clone it holds (or, when it holds none, from a probe of the
  // url it was configured with). So they answer for EVERY host, pooled or not,
  // and the value is the repository name rather than a status word: an
  // operator reads the table to see which machines are on which repository.
  const REPO_ACCESS_LABEL = { frameworkAccess: 'framework', projectAccess: 'project' };
  // Where each column's repository lives, reported beside the name it belongs to.
  const REPO_URL_KEY = { frameworkAccess: 'frameworkUrl', projectAccess: 'projectUrl' };
  const NO_ACCESS = 'No access';

  // The pool's separate question -- can this MEMBER read what its pool assigned
  // -- is answered in the host's registration record, and denied is the one
  // value that needs an operator. It rides the project cell's tooltip: the
  // column itself shows what the host holds, which is a different fact.
  const POOL_ACCESS_HINT = {
    denied: 'The pool assigned this host a project its git credential cannot read — grant its GH_TOKEN access to that repo, or reassign the pool to one every member can read. Its cycles fail until then, and no retry can fix it.',
    unreachable: 'The project this host’s pool assigned did not answer — network, not permission. Transient: the cycle’s clone retries through the normal backoff.'
  };

  // Raw value for a repository column, or '' when the host did not report one.
  function accessValue(h, key) {
    const f = facts[factKey(h)];
    if (!f || !f.ok) return '';
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
    const f = facts[factKey(h)];
    if (!f || !f.ok) return '';
    const s = String(f[REPO_URL_KEY[key]] || '').trim();
    if (!s) return '';
    try {
      const p = new URL(s).protocol;
      return (p === 'http:' || p === 'https:' || p === 'file:') ? s : '';
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
    if (!url) return Y.el('span', attrs, text);
    const linked = Object.assign({}, attrs, { href: url, target: '_blank', rel: 'noopener' });
    return Y.el('a', linked, text);
  }

  function accessCell(h, key, error) {
    const what = REPO_ACCESS_LABEL[key];
    const value = accessValue(h, key);
    const url = accessUrl(h, key);
    // The url ends the tooltip rather than sitting inside it: the cell shows a
    // name, and where that name came from is what an operator checks before
    // following the link.
    const where = url ? ' ' + url : '';
    const poolHint = key === 'projectAccess' ? POOL_ACCESS_HINT[h.access] : '';
    if (value === NO_ACCESS) {
      // Linked to the url it could NOT read, which is the one an operator
      // checks first: a url naming the wrong repository looks exactly like a
      // credential that is missing one until someone follows it.
      return repoEl(url, {
        title: 'This host cannot read the ' + what + ' repository it is configured with — check its git credential and the url in test.config.yml.' + where
      }, Y.el('strong', { text: NO_ACCESS }));
    }
    if (value) {
      return repoEl(url, {
        title: (poolHint ? poolHint + ' ' : '') + 'The ' + what + ' repository this host holds.' + where
      }, value);
    }
    return Y.el('span', {
      class: 'muted', text: '—',
      title: poolHint || error ||
        'This host has no ' + what + ' repository and none configured, or it has not answered yet.'
    });
  }

  // Two different blanks, and they need different answers from the operator:
  // withheld until this browser is unlocked, or a host that never reported one
  // (it has no address the pool can read a registration record from).
  function hostnameCell(name) {
    if (name) return Y.el('span', { text: name });
    return Y.el('span', {
      class: 'muted', text: '—',
      title: hostnamesVisible
        ? 'This host has not reported a name.'
        : 'Unlock with the Lab token to see hostnames.'
    });
  }

  function typeCell(type) {
    if (!type) return Y.el('span', { class: 'muted', text: '—' });
    return Y.el('span', { text: type });
  }

  // Which raw facts field backs each hardware column, for both cells and sort.
  const FACT_KEY = {
    memory: 'memoryBytes',
    cores: 'cores',
    storageTotal: 'storageTotalBytes',
    storageFree: 'storageFreeBytes'
  };

  // Bytes as an integer in the largest unit that keeps it at or under 1024:
  // 32 GiB RAM reads "32 GB", a 2 TB array reads "2 TB" rather than "2048 GB".
  function fmtBytes(n) {
    if (!(n > 0)) return null;
    for (const [name, div] of [['MB', 1048576], ['GB', 1073741824], ['TB', 1099511627776]]) {
      const v = Math.round(n / div);
      if (v <= 1024 || name === 'TB') return v + ' ' + name;
    }
  }

  // One blank for every way a fact can be missing (host silent, older host
  // build without the route, fan-out still unfetched); the title says which.
  // Takes a formatted string or a raw number (the Cores column).
  function factCell(value, error) {
    if (value !== null && value !== undefined && value !== '') return Y.el('span', { text: String(value) });
    return Y.el('span', { class: 'muted', text: '—', title: error || 'This host has not reported hardware facts.' });
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
    const f = facts[factKey(h)];
    if (!f || !f.ok) return null;
    const v = Number(f[FACT_KEY[key]]);
    return v > 0 ? v : null;
  }

  // Hardware columns sort on their raw numbers; every other column is a string
  // on the wire, so one comparison serves them all -- lowercased, because a
  // hostname's capitalisation is not a sort order anyone means to ask for.
  //
  // A discovered host that could not name itself has no id to sort on, so it
  // sorts on the address it answered at -- otherwise every such row would herd
  // to one end of the table as a blank, away from the machines beside it.
  function sortValue(h, key) {
    if (FACT_KEY[key]) return factValue(h, key);
    if (REPO_ACCESS_LABEL[key]) return accessValue(h, key).toLowerCase();
    if (key === 'hostId') return String(h.hostId || h.address || '').toLowerCase();
    return String(h[key] || '').toLowerCase();
  }

  function sorted(rows) {
    return rows.slice().sort(function (a, b) {
      const av = sortValue(a, sortKey);
      const bv = sortValue(b, sortKey);
      let cmp = 0;
      if (av !== bv) {
        // A row with no value ranks last ascending: sorting on a column is a
        // way of reading the rows that HAVE one, and this page is full of
        // blanks -- a withheld hostname, a host the pool cannot reach, a
        // hardware fact (null) from a host that never answered.
        if (av === '' || av === null) cmp = 1;
        else if (bv === '' || bv === null) cmp = -1;
        else cmp = av < bv ? -1 : 1;
      }
      if (!sortAsc) cmp = -cmp;
      if (cmp !== 0) return cmp;
      // Host ids are unique, so tying rows land in ONE order for a given column
      // rather than reshuffling under the operator on the next refresh.
      const ai = sortValue(a, 'hostId');
      const bi = sortValue(b, 'hostId');
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
    if (!h.discovered) return Y.hostLink(h.hostId, h.pool, goBaseUrl);
    const box = Y.el('span', { class: 'discovered-host' });
    if (h.hostId) box.appendChild(Y.el('span', { class: 'mono', text: Y.shortHost(h.hostId), title: h.hostId }));
    const seen = h.lastSeen ? ', last seen ' + new Date(h.lastSeen).toLocaleString() : '';
    if (h.baseUrl) {
      box.appendChild(Y.el('a', {
        class: 'mono', href: h.baseUrl, target: '_blank', rel: 'noopener',
        title: 'Open this host’s own status page at ' + h.baseUrl + ' (found by a network scan' + seen + ')'
      }, h.address));
    } else {
      box.appendChild(Y.el('span', { class: 'mono', text: h.address, title: 'Found by a network scan' + seen }));
    }
    box.appendChild(Y.el('span', { class: 'badge discovered', text: 'discovered', title: 'Found by scanning the network; it belongs to no pool and has not registered with the aggregator.' }));
    return box;
  }

  function rowEl(h) {
    const sel = Y.el('select', { 'aria-label': 'Pool for host ' + (h.hostId || h.address) });
    sel.appendChild(Y.el('option', { value: '', text: '(none)' }));
    for (const p of pools) {
      const o = Y.el('option', { value: p, text: p + (p === targetPoolId ? ' — auto-enrolment target' : '') });
      if (p === h.pool) o.selected = true;
      sel.appendChild(o);
    }
    sel.addEventListener('change', async () => {
      const to = sel.value;
      const label = to || '(none)';
      // (none) also records an exclusion, or the sweep would undo this within a
      // minute and the UI would look broken. Say so, rather than surprise them.
      const extra = to ? '' : '\n\nIt will also be excluded from auto-enrolment, so the sweep will not add it back.';
      if (!confirm('Move host ' + guid(h.hostId) + ' to ' + label + '?' + extra)) {
        sel.value = h.pool || '';
        return;
      }
      try {
        Y.clearNotice();
        await Y.mutate('/api/pool/move-host', { method: 'POST', body: { hostId: h.hostId, poolId: to } });
        await load();
      } catch (e) {
        sel.value = h.pool || '';
        Y.notice('error', e.message);
      }
    });

    // Pool membership is recorded against a host id, so a discovered host that
    // has not reported one cannot be put in a pool yet -- the picker says so
    // rather than failing on the far side of a confirm dialog.
    if (!h.hostId) {
      sel.disabled = true;
      sel.title = 'This host has not reported an id, so it cannot be assigned to a pool yet.';
    }

    const control = Y.el('span', { text: h.control, title: CONTROL_HINT[h.control] || '' });
    const f = facts[factKey(h)];
    const factErr = f && !f.ok ? (f.error || '') : '';
    return Y.el('tr', {}, [
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
    const body = document.getElementById('host-rows');
    body.textContent = '';
    for (const h of sorted(hosts)) body.appendChild(rowEl(h));
    const unlock = document.getElementById('show-hostnames');
    if (unlock) unlock.hidden = hostnamesVisible;
  }

  // The header cells carry the sort key; the buttons inside them are what the
  // keyboard and the screen reader act on, and aria-sort on the cell is what
  // announces the result. Clicking the sorted column reverses it.
  function initSort() {
    for (const th of document.querySelectorAll('th[data-sort]')) {
      const btn = th.querySelector('button');
      if (!btn) continue;
      btn.addEventListener('click', function () {
        const key = th.getAttribute('data-sort');
        if (key === sortKey) sortAsc = !sortAsc;
        else { sortKey = key; sortAsc = true; }
        markSorted();
        render();
      });
    }
    markSorted();
  }

  function markSorted() {
    for (const th of document.querySelectorAll('th[data-sort]')) {
      if (th.getAttribute('data-sort') === sortKey) {
        th.setAttribute('aria-sort', sortAsc ? 'ascending' : 'descending');
      } else {
        th.removeAttribute('aria-sort');
      }
    }
  }

  // quiet marks a read the operator did not ask for (the countdown's), which
  // keeps the rows it is refreshing on screen and signals in the footer. Every
  // other read replaces the table, so it says so: this one fans out to every
  // host in the lab and a silent machine holds it up for seconds.
  async function load(opts) {
    const quiet = !!(opts && opts.quiet);
    const done = quiet ? function () { } : Y.busy(document.getElementById('host-rows'), 'Loading hosts…');
    chrome.busy(true);
    try {
      // The hostname column turns on a session, and arriving from the dashboard
      // brings one in the URL fragment -- so wait for that exchange to settle
      // rather than fetching first and rendering a locked table to an operator
      // who is, a moment later, unlocked.
      await Y.ready();
      const d = await Y.api('/api/hosts');
      chrome.markLoaded();
      // Memoized and non-rejecting, so this is one read for the life of the page
      // and an aggregator this daemon does not know about just means unlinked ids.
      goBaseUrl = (await Y.hostInfo()).goBaseUrl || '';
      pools = d.pools || [];
      targetPoolId = d.targetPoolId || '';
      hosts = d.hosts || [];
      hostnamesVisible = !!d.hostnamesVisible;
      render();
      if (d.statusError) {
        Y.notice('warn', 'Aggregator unavailable (' + d.statusError + '); control state is unknown. Moving hosts still works.');
      } else {
        Y.clearNotice();
      }
    } catch (e) {
      Y.notice('error', e.message);
    } finally {
      done();
      chrome.busy(false);
    }
  }

  // Silent on failure by design: the table is fully usable without hardware
  // facts, and the columns' em-dash tooltips already say a host did not report.
  // It shows in the footer rather than over the table for the same reason: the
  // rows are already readable while these columns fill in.
  async function loadFacts() {
    chrome.busy(true);
    try {
      const d = await Y.api('/api/hosts/facts');
      facts = d.hosts || {};
      // Only a repaint of rows that exist. On first load these two reads race,
      // and painting an empty table here would take down the wait indicator the
      // host read is still under -- leaving a blank page mid-fetch.
      if (hosts.length) render();
    } catch (e) { /* facts keep their last value */ }
    finally { chrome.busy(false); }
  }

  document.getElementById('refresh').addEventListener('click', function () {
    load();
    loadFacts();
  });
  // The only control on this page that asks for the lab token up front. Every
  // other page prompts at the moment a change is attempted, but the hostname is
  // a READ that needs a session, so without this an operator who wants the
  // column has nothing to click.
  document.getElementById('show-hostnames').addEventListener('click', async () => {
    if (await Y.unlock()) await load();
  });
  initSort();
  // Header version + host id and the footer bar; its countdown re-reads the host
  // list rather than reloading, so a pending pool choice in a row survives. The
  // countdown deliberately does NOT re-fetch hardware facts (see `facts`).
  const chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });
  load();
  loadFacts();
})();
