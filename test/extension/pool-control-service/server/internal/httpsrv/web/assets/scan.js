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

  // --- REGION: CIDR validation
  // The field's job is to say what the daemon would say, before the round trip.
  // The daemon still validates: this is the same rule stated twice on purpose,
  // once where it is enforced and once where it can be fixed.
  var CIDR_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/;

  function validate(raw) {
    var value = String(raw || '').trim();
    if (value === '') { return { ok: false, message: window.YurunaI18n.t("pool.enter_a_network_for_example_value1", {value1: (defaultCidr || '192.168.7.0/24')}) }; }
    var m = CIDR_RE.exec(value);
    if (!m) { return { ok: false, message: window.YurunaI18n.t("pool.not_cidr_notation_write_an_address_a_slash_and_a_prefix_length_19") }; }
    for (var i = 1; i <= 4; i++) {
      if (Number(m[i]) > 255) { return { ok: false, message: window.YurunaI18n.t("pool.each_of_the_four_numbers_must_be_0_to_255") }; }
    }
    var bits = Number(m[5]);
    if (bits > 32) { return { ok: false, message: window.YurunaI18n.t("pool.the_prefix_length_must_be_0_to_32") }; }
    var size = Math.pow(2, 32 - bits);
    if (maxAddresses && size > maxAddresses) {
      return {
        ok: false,
        // Grouped from the locale manifest, like every other number the
        // project writes. toLocaleString would punctuate from the browser's
        // own locale regardless of the page's, so the same count would be
        // written one way here and another way in the transcript.
        message: window.YurunaI18n.t('pool.scan_limit', {prefix: bits, count: size, limit: num(maxAddresses)})
      };
    }
    // Said plainly rather than left to be inferred: the count is what tells an
    // operator whether they typed the network they meant.
    var hosts = bits <= 30 ? size - 2 : size;
    return { ok: true, message: window.YurunaI18n.t('pool.scan_count', {count: hosts}) };
  }

  // One place to reach the shared formatter, so a call site cannot quietly
  // fall back to the browser's own locale.
  function num(value) {
    return window.YurunaI18n.formatNumber(value, window.YurunaI18n.locale(), 0);
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

  // --- REGION: Rendering
  function fmtTime(iso) {
    if (!iso) { return '--'; }
    var d = new Date(iso);
    return isNaN(d.getTime()) ? iso : window.YurunaI18n.fmtLocal(d);
  }

  function renderProgress(scan) {
    var box = $('progress');
    var ticker = $('current');
    ticker.textContent = '';
    if (!scan || (!scan.running && !scan.startedUtc)) {
      box.className = 'muted';
      box.textContent = window.YurunaI18n.t("pool.no_scan_has_run_yet");
      return;
    }
    var what = window.YurunaI18n.t(scan.trigger === 'sweep' ? 'pool.sweep_label' : 'pool.scan_label');
    if (scan.running) {
      box.className = '';
      box.textContent = '';
      box.appendChild(Y.el('span', { text: window.YurunaI18n.t("pool.value1_of_value2_value3_of_value4_addresses", {value1: (what), value2: (scan.cidr), value3: (scan.done), value4: (scan.total)}) }));
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
    box.textContent = window.YurunaI18n.t('pool.scan_finished', {kind: what, network: scan.cidr, time: fmtTime(scan.finishedUtc), done: scan.done, total: scan.total, count: added, monitored: scan.alreadyMonitored, detail: scan.error || ''});
  }

  function renderFound(scan) {
    var body = $('found-rows');
    body.textContent = '';
    var found = (scan && scan.found) || [];
    if (!found.length) {
      body.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '5', class: 'muted', text: window.YurunaI18n.t("pool.nothing_new_every_yuruna_host_in_that_range_was_already_monitored") })]));
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
    if (!hostId) { return Y.el('span', { class: 'muted', text: window.YurunaI18n.t("pool.no_id_reported"), title: window.YurunaI18n.t("pool.this_host_answered_but_its_registration_record_could_not_be_read") }); }
    return Y.idCell(hostId);
  }

  function renderHosts(hosts) {
    return window.YurunaFirstUsable.measure("test/extension/pool-control-service/server/internal/httpsrv/web/scan.html", "data", function () {
      return renderHostsMeasured(hosts);
    });
  }


  function renderHostsMeasured(hosts) {
    var body = $('host-rows');
    body.textContent = '';
    if (!hosts || !hosts.length) {
      body.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '7', class: 'muted', text: window.YurunaI18n.t("pool.no_hosts_discovered_yet") })]));
      return;
    }
    for (var i = 0; i < hosts.length; i++) { body.appendChild(hostRow(hosts[i])); }
  }

  // One row, built in its own call so the Forget button closes over THIS host.
  // Wiring it from inside a loop body would leave every button aimed at the
  // last host in the table.
  function hostRow(h) {
    var forget = Y.el('button', { text: window.YurunaI18n.t("pool.forget") });
    forget.addEventListener('click', function () {
      if (!window.confirm(window.YurunaI18n.t("pool.stop_monitoring_value1_the_next_scan_of_that_network_will_find_it", {value1: (h.address)}))) { return; }
      forget.disabled = true;
      Y.clearNotice();
      Y.mutate('/api/scan/forget', { method: 'POST', body: { key: h.hostId || h.address } }).then(function () {
        return load();
      }, function (e) {
        forget.disabled = false;
        Y.notice('error', window.YurunaI18n.t("pool.could_not_forget_that_host_value1", {value1: (e.message)}));
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
    if (!data.sweepSeconds) { return window.YurunaI18n.t("pool.the_periodic_sweep_is_off_this_page_is_the_only_way_a_scan_runs"); }
    var minutes = Math.round(data.sweepSeconds / 60);
    return window.YurunaI18n.t(minutes >= 1 ? 'pool.sweep_minutes' : 'pool.sweep_seconds', {network: data.defaultCidr || window.YurunaI18n.t('pool.own_network'), count: minutes >= 1 ? minutes : data.sweepSeconds, port: data.port});
  }

  // --- REGION: Data
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
        Y.notice('error', window.YurunaI18n.t("pool.discovered_hosts_are_not_being_saved_value1", {value1: (data.storeError)}));
      }
      renderProgress(data.scan);
      renderFound(data.scan);
      renderHosts(data.hosts);
      renderSweepNote(data);
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/scan.html', data.hosts && data.hosts.length ? 'data' : 'empty');
      return data;
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.could_not_read_the_scan_status_value1", {value1: (e.message)}));
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/scan.html', 'error');
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
        Y.notice('ok', window.YurunaI18n.t("pool.a_scan_of_value1_is_already_running_following_that_one", {value1: (res.scan && res.scan.cidr)}));
      }
      renderProgress(res.scan);
      syncField();
      return poll();
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.scan_refused_value1", {value1: (e.message)}));
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
