// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Network scan: pick a range, watch it being walked, see what it added.
// No innerHTML on data.
(function () {
  // How often the page asks the daemon where the scan has got to. The scan
  // itself runs server-side (the sweep uses the same engine, and a browser
  // cannot read a cross-origin probe anyway), so this is the whole live view.
  // Fast enough that the address ticker reads as motion, slow enough that a
  // long scan is not thousands of requests.
  var POLL_MS = 700;

  var polling = false;
  var defaultCidr = '';
  var maxAddresses = 0;

  function $(id) { return document.getElementById(id); }

  var chrome = Y.initChrome({ refresh: function () { load(); } });

  // --- CIDR validation ------------------------------------------------------

  // The field's job is to say what the daemon would say, before the round trip.
  // The daemon still validates: this is the same rule stated twice on purpose,
  // once where it is enforced and once where it can be fixed.
  var CIDR_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/;

  function validate(raw) {
    var value = String(raw || '').trim();
    if (value === '') { return { ok: false, message: 'Enter a network, for example ' + (defaultCidr || '192.168.7.0/24') + '.' }; }
    var m = CIDR_RE.exec(value);
    if (!m) { return { ok: false, message: 'Not CIDR notation. Write an address, a slash, and a prefix length: 192.168.7.0/24.' }; }
    for (var i = 1; i <= 4; i++) {
      if (Number(m[i]) > 255) { return { ok: false, message: 'Each of the four numbers must be 0 to 255.' }; }
    }
    var bits = Number(m[5]);
    if (bits > 32) { return { ok: false, message: 'The prefix length must be 0 to 32.' }; }
    var size = Math.pow(2, 32 - bits);
    if (maxAddresses && size > maxAddresses) {
      return {
        ok: false,
        message: '/' + bits + ' covers ' + size.toLocaleString() + ' addresses; this service scans at most '
          + maxAddresses.toLocaleString() + '. Use a narrower network (a larger prefix length).'
      };
    }
    // Said plainly rather than left to be inferred: the count is what tells an
    // operator whether they typed the network they meant.
    var hosts = bits <= 30 ? size - 2 : size;
    return { ok: true, message: 'Scans ' + hosts.toLocaleString() + (hosts === 1 ? ' address.' : ' addresses.') };
  }

  function syncField() {
    var v = validate($('cidr').value);
    var hint = $('cidr-hint');
    hint.textContent = v.message;
    hint.className = v.ok ? 'hint' : 'hint scan-invalid';
    $('cidr').setAttribute('aria-invalid', v.ok ? 'false' : 'true');
    // Left enabled while a scan runs: pressing it then is answered with the
    // scan already in flight, which is a better response than a dead button
    // whose reason is off-screen.
    $('scan').disabled = !v.ok;
    return v.ok;
  }

  // --- rendering ------------------------------------------------------------

  function fmtTime(iso) {
    if (!iso) { return '--'; }
    var d = new Date(iso);
    return isNaN(d.getTime()) ? iso : d.toLocaleString();
  }

  function renderProgress(scan) {
    var box = $('progress');
    var ticker = $('current');
    ticker.textContent = '';
    if (!scan || (!scan.running && !scan.startedUtc)) {
      box.className = 'muted';
      box.textContent = 'No scan has run yet.';
      return;
    }
    var what = scan.trigger === 'sweep' ? 'Periodic sweep' : 'Scan';
    if (scan.running) {
      box.className = '';
      box.textContent = '';
      box.appendChild(Y.el('span', { text: what + ' of ' + scan.cidr + ': ' + scan.done + ' of ' + scan.total + ' addresses. ' }));
      box.appendChild(Y.el('progress', { value: String(scan.done), max: String(scan.total) }));
      // The addresses just probed, oldest first, so the line reads left to
      // right the way the scan moved through the range.
      if (scan.recent && scan.recent.length) {
        ticker.appendChild(Y.el('span', { class: 'mono', text: scan.recent.join('  -  ') }));
      }
      return;
    }
    box.className = 'muted';
    var added = (scan.found || []).length;
    box.textContent = what + ' of ' + scan.cidr + ' finished ' + fmtTime(scan.finishedUtc) + ': '
      + scan.done + ' of ' + scan.total + ' addresses probed, '
      + added + (added === 1 ? ' host added, ' : ' hosts added, ')
      + scan.alreadyMonitored + ' already monitored.'
      + (scan.error ? ' ' + scan.error : '');
  }

  function renderFound(scan) {
    var body = $('found-rows');
    body.textContent = '';
    var found = (scan && scan.found) || [];
    if (!found.length) {
      body.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '5', class: 'muted', text: 'Nothing new. Every Yuruna host in that range was already monitored.' })]));
      return;
    }
    for (var i = 0; i < found.length; i++) {
      var h = found[i];
      body.appendChild(Y.el('tr', {}, [
        Y.el('td', { class: 'mono', text: h.address }),
        Y.el('td', {}, [idCell(h.hostId)]),
        Y.el('td', { text: h.hostname || '--' }),
        Y.el('td', { text: h.hostType || '--' }),
        Y.el('td', { text: fmtTime(h.firstSeenUtc) })
      ]));
    }
  }

  // A host that answered but would not name itself is still a host worth
  // watching; it is identified by address until it says otherwise, and the
  // blank says which case this is rather than pretending to an id.
  function idCell(hostId) {
    if (!hostId) { return Y.el('span', { class: 'muted', text: '(no id reported)', title: 'This host answered but its registration record could not be read.' }); }
    return Y.idCell(hostId);
  }

  function renderHosts(hosts) {
    var body = $('host-rows');
    body.textContent = '';
    if (!hosts || !hosts.length) {
      body.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '7', class: 'muted', text: 'No hosts discovered yet.' })]));
      return;
    }
    for (var i = 0; i < hosts.length; i++) { body.appendChild(hostRow(hosts[i])); }
  }

  // One row, built in its own call so the Forget button closes over THIS host.
  // Wiring it from inside a loop body would leave every button aimed at the
  // last host in the table.
  function hostRow(h) {
    var forget = Y.el('button', { text: 'Forget' });
    forget.addEventListener('click', function () {
      if (!window.confirm('Stop monitoring ' + h.address + '?\n\nThe next scan of that network will find it again if it is still there.')) { return; }
      forget.disabled = true;
      Y.clearNotice();
      Y.mutate('/api/scan/forget', { method: 'POST', body: { key: h.hostId || h.address } }).then(function () {
        return load();
      }, function (e) {
        forget.disabled = false;
        Y.notice('error', 'Could not forget that host: ' + e.message);
      });
    });
    // The address links to the host's own status service, which for a host that
    // registered with nobody is the only way to reach it. No base means the
    // prober did not say which port answered, and plain text beats a link that
    // cannot work.
    var where = h.baseUrl
      ? Y.el('a', { href: h.baseUrl, target: '_blank', rel: 'noopener', title: h.baseUrl, text: h.address })
      : Y.el('span', { text: h.address });
    return Y.el('tr', {}, [
      Y.el('td', { class: 'mono' }, [where]),
      Y.el('td', {}, [idCell(h.hostId)]),
      Y.el('td', { text: h.hostname || '--' }),
      Y.el('td', { text: h.hostType || '--' }),
      Y.el('td', { text: fmtTime(h.firstSeenUtc) }),
      Y.el('td', { text: fmtTime(h.lastSeenUtc) }),
      Y.el('td', {}, [forget])
    ]);
  }

  // What happens without the operator: the cadence, the range it sweeps, and
  // the port it asks on. Its own line, because the hint above it belongs to the
  // field and the two would otherwise overwrite each other.
  function renderSweepNote(data) {
    $('sweep-note').textContent = sweepSentence(data);
  }

  function sweepSentence(data) {
    if (!data.sweepSeconds) { return 'The periodic sweep is off; this page is the only way a scan runs.'; }
    var minutes = Math.round(data.sweepSeconds / 60);
    return 'A sweep of ' + (data.defaultCidr || 'this service\'s own network') + ' runs on its own every '
      + (minutes >= 1 ? minutes + (minutes === 1 ? ' minute' : ' minutes') : data.sweepSeconds + ' seconds')
      + ', asking port ' + data.port + ' on every address.';
  }

  // --- data -----------------------------------------------------------------

  function load() {
    return Y.api('/api/scan').then(function (data) {
      chrome.markLoaded();
      defaultCidr = data.defaultCidr || '';
      maxAddresses = data.maxAddresses || 0;
      // Only when the operator has not typed: a poll must never take the field
      // out from under someone in the middle of editing it.
      if (!$('cidr').value) {
        $('cidr').value = defaultCidr;
        syncField();
      }
      if (data.storeError) {
        Y.notice('error', 'Discovered hosts are not being saved: ' + data.storeError);
      }
      renderProgress(data.scan);
      renderFound(data.scan);
      renderHosts(data.hosts);
      renderSweepNote(data);
      return data;
    }, function (e) {
      Y.notice('error', 'Could not read the scan status: ' + e.message);
      return null;
    });
  }

  // poll follows a running scan to its end, then does one final read so the
  // monitored list below includes whatever the run just added.
  //
  // Written as a chain that re-enters itself rather than as a loop: without
  // async/await there is no way to suspend inside one, and a self-scheduling
  // step is the shape that keeps the "read, wait, read again" order exact.
  function poll() {
    if (polling) { return Promise.resolve(); }
    polling = true;
    var stop = function () { polling = false; };
    function step() {
      return load().then(function (data) {
        if (!data || !data.scan || !data.scan.running) { return null; }
        return new Promise(function (r) { window.setTimeout(r, POLL_MS); }).then(step);
      });
    }
    return step().then(stop, stop);
  }

  function startScan() {
    if (!syncField()) { return Promise.resolve(); }
    var cidr = $('cidr').value.trim();
    Y.clearNotice();
    $('scan').disabled = true;
    return Y.mutate('/api/scan', { method: 'POST', body: { cidr: cidr } }).then(function (res) {
      if (res.alreadyRunning) {
        Y.notice('ok', 'A scan of ' + (res.scan && res.scan.cidr) + ' is already running; following that one.');
      }
      renderProgress(res.scan);
      syncField();
      return poll();
    }, function (e) {
      Y.notice('error', 'Scan refused: ' + e.message);
      syncField();
    });
  }

  $('cidr').addEventListener('input', syncField);
  $('cidr').addEventListener('keydown', function (e) {
    // Enter in a lone text field means "do the thing the field is for". There
    // is no <form> here, so nothing else would answer it.
    if (Y.key(e) === 'Enter') { e.preventDefault(); startScan(); }
  });
  // Wrapped rather than passed straight to the listener: startScan takes no
  // arguments, and a DOM event is not one.
  $('scan').addEventListener('click', function () { startScan(); });
  $('use-default').addEventListener('click', function () {
    $('cidr').value = defaultCidr;
    syncField();
  });

  document.addEventListener('DOMContentLoaded', function () {
    load().then(function (data) {
      // A sweep may already be walking the network when the page opens; follow
      // it rather than showing a frozen snapshot of someone else's scan.
      if (data && data.scan && data.scan.running) { poll(); }
    });
  });
})();
