// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Create page: paste text or upload file(s) (stash-service-ui.md §5). Both
// post to /api/stashes and redirect to the new stash on success (§5.4).

(function () {
  const $ = (id) => document.getElementById(id);

  function showTab(which) {
    const text = which === 'text';
    $('tab-text').classList.toggle('active', text);
    $('tab-files').classList.toggle('active', !text);
    $('form-text').style.display = text ? '' : 'none';
    $('form-files').style.display = text ? 'none' : '';
  }
  $('tab-text').addEventListener('click', () => showTab('text'));
  $('tab-files').addEventListener('click', () => showTab('files'));

  function msg(kind, text) {
    $('msg').replaceChildren(Y.el('div', { class: 'notice ' + kind, text }));
  }

  async function submitCreate(form, btn) {
    btn.disabled = true;
    try {
      const data = await Y.api('/api/stashes', { method: 'POST', body: new FormData(form) });
      // Redirect to the new stash detail view (§5.4).
      location.href = data.permalink;
    } catch (e) {
      msg('error', 'Create failed: ' + e.message);
      btn.disabled = false;
    }
  }

  $('form-text').addEventListener('submit', (ev) => {
    ev.preventDefault();
    if (!$('text').value) { msg('warn', 'Nothing to store — paste some content first.'); return; }
    submitCreate($('form-text'), ev.submitter || $('form-text').querySelector('button'));
  });

  $('form-files').addEventListener('submit', (ev) => {
    ev.preventDefault();
    if (!$('files').files.length) { msg('warn', 'Choose at least one file.'); return; }
    submitCreate($('form-files'), ev.submitter || $('form-files').querySelector('button'));
  });
})();
