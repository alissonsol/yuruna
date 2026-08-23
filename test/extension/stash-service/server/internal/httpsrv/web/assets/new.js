// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Create page: paste text or upload file(s). Both post to /api/stashes and
// redirect to the new stash on success (section 5.4).

(function () {
  function $(id) { return document.getElementById(id); }

  // add/remove rather than classList.toggle's force argument, which the browser
  // baseline does not carry everywhere.
  function setActive(el, on) {
    if (on) { el.className = el.className.indexOf('active') >= 0 ? el.className : (el.className + ' active').replace(/^\s+/, ''); }
    else { el.className = el.className.replace(/\bactive\b/g, '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, ''); }
  }

  function showTab(which) {
    var text = which === 'text';
    // aria-selected alongside the class, not instead of it: the class carries
    // the look and the attribute carries the state, and a reader that only had
    // the class would hear two tabs with nothing to say which one is showing.
    setActive($('tab-text'), text);
    $('tab-text').setAttribute('aria-selected', String(text));
    setActive($('tab-files'), !text);
    $('tab-files').setAttribute('aria-selected', String(!text));
    $('form-text').style.display = text ? '' : 'none';
    $('form-files').style.display = text ? 'none' : '';
  }
  $('tab-text').addEventListener('click', function () { showTab('text'); });
  $('tab-files').addEventListener('click', function () { showTab('files'); });

  function msg(kind, text) {
    Y.replace($('msg'), Y.el('div', { class: 'notice ' + kind, text: text }));
  }

  function submitCreate(form, btn) {
    btn.disabled = true;
    // FormData, so Y.api sends it as the multipart upload it is rather than
    // serializing it -- the daemon parses the file out of the boundary.
    return Y.api('/api/stashes', { method: 'POST', body: new FormData(form) }).then(function (data) {
      window.location.href = data.permalink;
    }, function (e) {
      msg('error', 'Create failed: ' + e.message);
      btn.disabled = false;
    });
  }

  // ev.submitter is Safari 15.4+, so the query is the path the browser baseline
  // actually takes: on a form with one button the two agree.
  function submitterOf(ev, form) {
    return ev.submitter || form.querySelector('button');
  }

  $('form-text').addEventListener('submit', function (ev) {
    ev.preventDefault();
    if (!$('text').value) { msg('warn', 'Nothing to store -- paste some content first.'); return; }
    submitCreate($('form-text'), submitterOf(ev, $('form-text')));
  });

  $('form-files').addEventListener('submit', function (ev) {
    ev.preventDefault();
    if (!$('files').files.length) { msg('warn', 'Choose at least one file.'); return; }
    submitCreate($('form-files'), submitterOf(ev, $('form-files')));
  });

  // Shared footer bar: server IPs and the last-loaded time. This page carries no
  // #countdown, so nothing here auto-refreshes -- a timed reload would discard
  // the form above.
  Y.initFooter();
})();
