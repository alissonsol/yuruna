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
    var done = quiet ? function () { } : Y.busy(document.getElementById('ts-rows'), 'Loading test sets...');
    chrome.busy(true);
    // Runs on the failure path too: an indicator left turning over a read that
    // already failed claims progress that is not happening.
    var finish = function () { done(); chrome.busy(false); window.YurunaFirstUsable.release('primary'); };
    return renderSets().then(finish, finish);
  }

  function renderSets() {
    Y.clearNotice();
    return Y.api('/api/state').then(function (data) {
      chrome.markLoaded();
      paintSets(data.testSets || []);
    }, function (e) {
      Y.notice('error', 'Could not load test sets: ' + e.message);
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/test-sets.html', 'error');
    });
  }

  function paintSets(sets) {
    var tbody = document.getElementById('ts-rows');
    if (Y.holdRepaint(tbody, renderSets)) { return; }
    tbody.textContent = '';
    if (sets.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '5', class: 'muted', text: 'No test sets yet.' })]));
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
    var editBtn = Y.el('button', { text: 'Edit' });
    editBtn.addEventListener('click', function () {
      document.getElementById('ts-name').value = t.name;
      document.getElementById('ts-framework').value = t.frameworkUrl;
      document.getElementById('ts-project').value = t.projectUrl;
    });
    var delBtn = Y.el('button', { text: 'Delete', 'aria-label': 'Delete test set ' + t.name });
    delBtn.addEventListener('click', function () {
      if (!window.confirm("Delete test set '" + t.name + "'? This cannot be undone.")) { return; }
      delBtn.disabled = true;
      Y.mutate('/api/testset?name=' + encodeURIComponent(t.name), { method: 'DELETE' }).then(function () {
        Y.notice('ok', "Deleted '" + t.name + "'.");
        load();
      }, function (e) {
        Y.notice('error', 'Delete failed: ' + e.message);
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
    if (!name || !fw || !proj) { Y.notice('error', 'name, frameworkUrl and projectUrl are all required.'); return; }
    Y.mutate('/api/testset', { method: 'POST', body: { name: name, frameworkURL: fw, projectURL: proj } }).then(function () {
      Y.notice('ok', "Saved test set '" + name + "'.");
      load();
    }, function (e) {
      Y.notice('error', 'Save failed: ' + e.message);
    });
  });

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
