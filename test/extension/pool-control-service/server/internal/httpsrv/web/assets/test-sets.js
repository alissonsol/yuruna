// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Test-set library CRUD: named {name, frameworkUrl, projectUrl} triples. No GH_TOKEN.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads the
  // library rather than reloading, so a half-typed test set is not wiped.
  var chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });

  // Built once, not per read: the sort an operator chose is theirs until they
  // change it, and re-reading the library every minute must not put the table
  // back in the server's order under them.
  var sorter = Y.sortTable(document.getElementById('ts-rows'), { key: 'name' });

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: the library is read by
  // running a CLI on the server, which is not instant.
  function load(opts) {
    window.YurunaFirstUsable.hold('primary');
    var quiet = !!(opts && opts.quiet);
    var done = quiet ? function () { } : Y.busy(document.getElementById('ts-rows'), window.YurunaI18n.t("pool.loading_test_sets"));
    chrome.busy(true);
    // Runs on the failure path too: an indicator left turning over a read that
    // already failed claims progress that is not happening.
    var finish = function () { done(); chrome.busy(false); window.YurunaFirstUsable.release('primary'); };
    return renderSets().then(finish, finish);
  }

  function renderSets() {
    return window.YurunaFirstUsable.measure("test/extension/pool-control-service/server/internal/httpsrv/web/test-sets.html", "data", function () {
      return renderSetsMeasured();
    });
  }


  function renderSetsMeasured() {
    Y.clearNotice();
    return Y.api('/api/state').then(function (data) {
      chrome.markLoaded();
      paintSets(data.testSets || []);
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.could_not_load_test_sets_value1", {value1: (e.message)}));
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/test-sets.html', 'error');
    });
  }

  function paintSets(sets) {
    var tbody = document.getElementById('ts-rows');
    if (Y.holdRepaint(tbody, renderSets)) { return; }
    tbody.textContent = '';
    if (sets.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '5', class: 'muted', text: window.YurunaI18n.t("pool.no_test_sets_yet") })]));
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/test-sets.html', 'empty');
      return;
    }
    var rows = [];
    for (var i = 0; i < sets.length; i++) { rows.push(buildRow(sets[i])); }
    sorter.set(rows);
    window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/test-sets.html', 'data');
  }

  // One row, built in its own call so the handlers below close over THIS test
  // set. Wiring them from inside a loop body would leave every button holding
  // the last row's name.
  function buildRow(t) {
    var editBtn = Y.el('button', { text: window.YurunaI18n.t("pool.edit") });
    editBtn.addEventListener('click', function () {
      document.getElementById('ts-name').value = t.name;
      document.getElementById('ts-framework').value = t.frameworkUrl;
      document.getElementById('ts-project').value = t.projectUrl;
    });
    var delBtn = Y.el('button', { text: window.YurunaI18n.t("pool.delete"), 'aria-label': window.YurunaI18n.t("pool.delete_test_set_value1", {value1: (t.name)}) });
    delBtn.addEventListener('click', function () {
      if (!window.confirm(window.YurunaI18n.t("pool.delete_test_set_value1_this_cannot_be_undone", {value1: (t.name)}))) { return; }
      delBtn.disabled = true;
      Y.mutate('/api/testset?name=' + encodeURIComponent(t.name), { method: 'DELETE' }).then(function () {
        Y.notice('ok', window.YurunaI18n.t("pool.deleted_value1", {value1: (t.name)}));
        load();
      }, function (e) {
        Y.notice('error', window.YurunaI18n.t("pool.delete_failed_value1", {value1: (e.message)}));
        delBtn.disabled = false;
      });
    });
    return {
      tr: Y.el('tr', {}, [
        Y.el('td', { text: t.name }),
        Y.el('td', { class: 'mono', text: t.frameworkUrl }),
        Y.el('td', { class: 'mono', text: t.projectUrl }),
        Y.el('td', {}, [editBtn, ' ', delBtn])
      ]),
      values: {
        name: t.name || '',
        frameworkUrl: t.frameworkUrl || '',
        projectUrl: t.projectUrl || ''
      }
    };
  }

  document.getElementById('save').addEventListener('click', function () {
    var name = document.getElementById('ts-name').value.trim();
    var fw = document.getElementById('ts-framework').value.trim();
    var proj = document.getElementById('ts-project').value.trim();
    if (!name || !fw || !proj) { Y.notice('error', window.YurunaI18n.t("pool.name_frameworkurl_and_projecturl_are_all_required")); return; }
    Y.mutate('/api/testset', { method: 'POST', body: { name: name, frameworkURL: fw, projectURL: proj } }).then(function () {
      Y.notice('ok', window.YurunaI18n.t("pool.saved_test_set_value1", {value1: (name)}));
      load();
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.save_failed_value1", {value1: (e.message)}));
    });
  });

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
