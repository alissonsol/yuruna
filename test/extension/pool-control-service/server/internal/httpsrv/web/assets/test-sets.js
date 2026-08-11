// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Test-set library CRUD: named {name, frameworkUrl, projectUrl} triples. No GH_TOKEN.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads the
  // library rather than reloading, so a half-typed test set is not wiped.
  const chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: the library is read by
  // running a CLI on the server, which is not instant.
  async function load(opts) {
    const quiet = !!(opts && opts.quiet);
    const done = quiet ? function () { } : Y.busy(document.getElementById('ts-rows'), 'Loading test sets…');
    chrome.busy(true);
    try {
      await renderSets();
    } finally {
      // Also on the failure path: an indicator left turning over a read that
      // already failed claims progress that is not happening.
      done();
      chrome.busy(false);
    }
  }

  async function renderSets() {
    Y.clearNotice();
    let data;
    try { data = await Y.api('/api/state'); }
    catch (e) { Y.notice('error', 'Could not load test sets: ' + e.message); return; }
    chrome.markLoaded();
    const sets = data.testSets || [];
    const tbody = document.getElementById('ts-rows');
    tbody.textContent = '';
    if (sets.length === 0) {
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '4', class: 'muted', text: 'No test sets yet.' })]));
      return;
    }
    for (const t of sets) {
      const editBtn = Y.el('button', { text: 'Edit' });
      editBtn.addEventListener('click', function () {
        document.getElementById('ts-name').value = t.name;
        document.getElementById('ts-framework').value = t.frameworkUrl;
        document.getElementById('ts-project').value = t.projectUrl;
      });
      const delBtn = Y.el('button', { text: 'Delete' });
      delBtn.addEventListener('click', async function () {
        delBtn.disabled = true;
        try { await Y.mutate('/api/testset?name=' + encodeURIComponent(t.name), { method: 'DELETE' }); Y.notice('ok', "Deleted '" + t.name + "'."); load(); }
        catch (e) { Y.notice('error', 'Delete failed: ' + e.message); delBtn.disabled = false; }
      });
      tbody.appendChild(Y.el('tr', {}, [
        Y.el('td', { text: t.name }),
        Y.el('td', { class: 'mono', text: t.frameworkUrl }),
        Y.el('td', { class: 'mono', text: t.projectUrl }),
        Y.el('td', {}, [editBtn, ' ', delBtn])
      ]));
    }
  }

  document.getElementById('save').addEventListener('click', async function () {
    const name = document.getElementById('ts-name').value.trim();
    const fw = document.getElementById('ts-framework').value.trim();
    const proj = document.getElementById('ts-project').value.trim();
    if (!name || !fw || !proj) { Y.notice('error', 'name, frameworkUrl and projectUrl are all required.'); return; }
    try {
      await Y.mutate('/api/testset', { method: 'POST', body: { name: name, frameworkURL: fw, projectURL: proj } });
      Y.notice('ok', "Saved test set '" + name + "'.");
      load();
    } catch (e) { Y.notice('error', 'Save failed: ' + e.message); }
  });

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
