// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Content-class previews and downloads; deletion requires an unlocked session.

(function () {
  var TEXT_PREVIEW_CAP = 1024 * 1024; // fallback if the server omits inlineTextCap (section 6.2)
  var state = { inlineTextCap: 0 };
  function $(id) { return document.getElementById(id); }

  // Removing /s preserves both the full permalink and the host-local alias.
  function apiPath() {
    var parts = window.location.pathname.split('/').filter(Boolean); // [s, ...]
    return '/api/stashes/' + parts.slice(1).join('/');
  }

  function msg(kind, text) {
    Y.replace($('msg'), Y.el('div', { class: 'notice ' + kind, text: text }));
  }

  function meta(v) {
    var dl = Y.el('dl', { class: 'kv' });
    var add = function (k, val) { Y.append(dl, Y.el('dt', { text: k }), Y.el('dd', { text: val })); };
    add('ID', v.id);
    add(window.YurunaI18n.t("stash.name"), v.originalFilename || window.YurunaI18n.t('stash.unnamed'));
    add(window.YurunaI18n.t("stash.host"), v.local ? window.YurunaI18n.t('stash.local_host_name', {host: Y.guid(v.hostId)}) : Y.guid(v.hostId));
    add(window.YurunaI18n.t("stash.type"), (v.mimeType || v.contentClass) + (v.typeLabel ? '  [' + v.typeLabel + ']' : ''));
    add(window.YurunaI18n.t("stash.size"), Y.humanSize(v.sizeBytes));
    add(window.YurunaI18n.t("stash.user"), v.username);
    add(window.YurunaI18n.t("stash.source"), v.source || 'scp');
    add(window.YurunaI18n.t("stash.status"), Y.displayState(v.status));
    if (v.pathMetadata) { add(window.YurunaI18n.t("stash.scp_path"), v.pathMetadata); }
    add(window.YurunaI18n.t("stash.created"), Y.fmtDate(v.createdAt));
    if (v.receivedAt) { add(window.YurunaI18n.t("stash.received"), Y.fmtDate(v.receivedAt)); }
    if (v.local) { add(window.YurunaI18n.t("stash.short_link"), window.location.origin + '/' + v.id); }
    add(window.YurunaI18n.t("stash.permalink"), window.location.origin + v.permalink);
    return dl;
  }

  // gate carries what /api/session says about THIS browser: whether it is
  // through the delete gate. Nothing on the page reveals that -- it is a fact
  // about a credential this device holds -- so without asking, this page would
  // offer a button whose refusal is only discoverable by pressing it.
  //
  // A stash owned by another host is deletable here too: the daemon writes to
  // every host's folder on the stash share. Its owner is still named, because
  // which machine received a stash stays worth knowing.
  function actions(v, gate) {
    var box = Y.el('div', { class: 'actions' });
    Y.append(box, Y.el('a', { class: 'btn primary', href: Y.downloadURL(v), download: v.originalFilename || v.id, text: window.YurunaI18n.t("stash.download") }));
    if (gate.canDelete) {
      Y.append(box, Y.el('button', { class: 'btn destructive', onclick: function () { confirmDelete(v); } }, window.YurunaI18n.t("stash.delete")));
    } else {
      Y.append(box, Y.el('button', { class: 'btn destructive', disabled: 'disabled', title: window.YurunaI18n.t("stash.unlock_actions_to_delete") }, window.YurunaI18n.t("stash.delete")));
      Y.append(box, Y.el('span', { class: 'muted' }, gate.labToken ? window.YurunaI18n.t("stash.locked_unlock_actions_with_the_lab_token_above_or_open_this_page_") : window.YurunaI18n.t("stash.delete_is_unavailable_this_service_has_no_pool_aggregator_configu_9d79c432")));
    }
    if (!v.local) {
      var where = Y.el('span', { class: 'muted', title: Y.guid(v.hostId), text: window.YurunaI18n.t('stash.received_host', {host: Y.shortHost(v.hostId)}) });
      if (v.remoteStashUrl) {
        Y.append(where, ' -- ', Y.el('a', { href: v.remoteStashUrl, text: window.YurunaI18n.t("stash.open_on_that_host") }));
      }
      Y.append(box, where);
    }
    return box;
  }

  function confirmDelete(v) {
    if (!window.confirm(window.YurunaI18n.t("stash.delete_stash_value1_value2_value3_this_cannot_be_undone", {value1: (v.id), value2: (v.originalFilename || 'unnamed'), value3: (Y.humanSize(v.sizeBytes))}))) { return Promise.resolve(); }
    // Same barrier as the list page: from here on this page is describing a
    // stash that is going away, and its Download button would fail for a reason
    // that looks like the page's fault.
    var done = Y.block(window.YurunaI18n.t("stash.deleting"));
    return Y.api(apiPath(), { method: 'DELETE' }).then(function () {
      // Deliberately NOT released here: the browser is leaving, and a page that
      // became clickable again while the next one loads would reopen the very
      // gap this closes. The navigation takes the barrier with it.
      // Route even this static destination through the shared safeUrl gate so
      // every navigation in the UI passes one same-origin check.
      window.location.href = Y.safeUrl('/') || '/';
    }, function (e) {
      done();
      msg('error', window.YurunaI18n.t("stash.delete_failed_value1", {value1: (e.message)}));
    });
  }

  // Resolves with the built card. The two classes that have to fetch more
  // (text, archive) are why this answers a promise at all; every other class is
  // ready the moment the element exists.
  function renderViewer(v) {
    var wrap = Y.el('div', { class: 'card' });
    if (v.status === 'pending') {
      Y.append(wrap, Y.el('div', { class: 'muted', text: window.YurunaI18n.t("stash.still_receiving_no_preview_yet") }));
      return Promise.resolve(wrap);
    }
    if (v.status === 'partial') {
      Y.append(wrap, Y.el('div', { class: 'muted', text: window.YurunaI18n.t("stash.incomplete_upload_partial_bytes_available_via_download") }));
      return Promise.resolve(wrap);
    }
    if (v.status === 'truncated') {
      Y.append(wrap, Y.el('div', { class: 'notice warn', text: window.YurunaI18n.t("stash.truncated_at_the_100_mb_cap_download_serves_the_capped_artifact") }));
    }

    var raw = Y.rawURL(v);
    switch (v.contentClass) {
      case 'image':
        return renderMedia(wrap, Y.el('img', { class: 'viewer-img', alt: v.originalFilename || v.id }), raw, 'load');
      case 'pdf':
        Y.append(wrap, Y.el('embed', { class: 'viewer-frame', src: raw, type: 'application/pdf', title: window.YurunaI18n.t("stash.value1_pdf_preview", {value1: (v.originalFilename || v.id)}) }));
        // The link stays usable when a mobile browser cannot render <embed>.
        Y.append(wrap, Y.el('p', { class: 'notice' },
          Y.el('a', { href: raw, target: '_blank', rel: 'noopener', text: window.YurunaI18n.t("stash.open_pdf") })));
        break;
      case 'audio':
        return renderMedia(wrap, Y.el('audio', { class: 'viewer-av', controls: 'controls' }), raw, 'loadedmetadata');
      case 'video':
        return renderMedia(wrap, Y.el('video', { class: 'viewer-av', controls: 'controls' }), raw, 'loadedmetadata');
      case 'text':
        return renderText(wrap, raw).then(function () { return wrap; });
      case 'archive':
        return renderArchive(wrap, v).then(function () { return wrap; });
      default:
        Y.append(wrap, Y.el('div', { class: 'muted', text: window.YurunaI18n.t("stash.no_inline_preview_for_this_type_download_to_view") }));
    }
    return Promise.resolve(wrap);
  }

  // --- REGION: renderMedia
  function renderMedia(wrap, media, raw, event) {
    wrap.yurunaReadyPromise = new Promise(function (resolve) {
      media.addEventListener(event, function () { resolve(wrap); });
      media.addEventListener('error', function () {
        wrap.yurunaReadyState = 'error';
        Y.append(wrap, Y.el('div', { class: 'notice error', role: 'alert', text: window.YurunaI18n.t("stash.preview_unavailable_use_download_to_open_the_file") }));
        resolve(wrap);
      });
      Y.append(wrap, media);
      media.src = raw;
    });
    return Promise.resolve(wrap);
  }

  function renderText(wrap, raw) {
    return window.fetch(raw).then(function (res) {
      if (!res.ok) {
        wrap.yurunaReadyState = 'error';
        Y.append(wrap, Y.el('div', { class: 'notice error', text: window.YurunaI18n.t("stash.could_not_load_text_http_value1", {value1: (res.status)}) }));
        return null;
      }
      return res.text().then(function (buf) {
        var body = buf;
        var truncated = false;
        var cap = state.inlineTextCap || TEXT_PREVIEW_CAP;
        if (body.length > cap) { body = body.slice(0, cap); truncated = true; }
        var pre = Y.el('pre', { class: 'viewer wrap', tabindex: '0', role: 'region', 'aria-label': window.YurunaI18n.t("stash.stash_text_preview") });
        pre.textContent = body; // textContent: never interpret as HTML (section 7.4)
        if (!body) { wrap.yurunaReadyState = 'empty'; }
        if (truncated) { Y.append(wrap, Y.el('div', { class: 'notice warn', text: window.YurunaI18n.t("stash.preview_truncated_download_for_the_full_content") })); }
        Y.append(wrap, pre);
        return null;
      });
    }, function (e) {
      wrap.yurunaReadyState = 'error';
      Y.append(wrap, Y.el('div', { class: 'notice error', text: window.YurunaI18n.t("stash.could_not_load_text_value1", {value1: (e.message)}) }));
    });
  }

  function renderArchive(wrap, v) {
    Y.append(wrap, Y.el('div', { class: 'muted', text: window.YurunaI18n.t("stash.archive_value1_contents", {value1: (Y.humanSize(v.sizeBytes))}) }));
    return Y.api(apiPath() + '/archive').then(function (data) {
      var tbl = Y.el('table', { class: 'stashes' });
      Y.append(tbl, Y.el('caption', { class: 'sr-only', text: window.YurunaI18n.t("stash.archive_contents") }));
      var th = Y.el('thead');
      Y.append(th, Y.el('tr', {},
        Y.el('th', { scope: 'col', text: window.YurunaI18n.t("stash.name") }),
        Y.el('th', { scope: 'col', class: 'num', text: window.YurunaI18n.t("stash.size") })));
      Y.append(tbl, th);
      var tb = Y.el('tbody');
      var entries = data.entries || [];
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        Y.append(tb, Y.el('tr', {},
          Y.el('td', { class: 'mono', text: e.name }),
          Y.el('td', { class: 'num', text: e.dir ? '' : Y.humanSize(e.size) })));
      }
      Y.append(tbl, tb);
      Y.append(wrap, tbl);
    }, function (e) {
      wrap.yurunaReadyState = 'error';
      Y.append(wrap, Y.el('div', { class: 'notice error', text: window.YurunaI18n.t("stash.could_not_list_archive_value1", {value1: (e.message)}) }));
    });
  }

  function load() {
    // Resolve proof/session before controls. Catch in a separate chain link
    // so rejected reads and renders both reach the accessible error state.
    return Y.initUnlock(load).then(function (sess) {
      return Y.api(apiPath()).then(function (data) {
        var v = data.stash;
        state.inlineTextCap = data.inlineTextCap || 0;
        return renderViewer(v).then(function (viewer) {
          window.YurunaFirstUsable.measure('test/extension/stash-service/server/internal/httpsrv/web/stash.html', 'data', function () {
          // Page first, service second, so a row of open tabs stays tellable
          // apart.
          document.title = window.YurunaI18n.t("stash.value1_yuruna_stash", {value1: (v.originalFilename || v.id)});
          var detail = $('detail');
          detail.className = '';
          Y.replace(detail,
            Y.el('h1', { text: v.originalFilename || v.id }),
            actions(v, { canDelete: sess.authed, labToken: sess.labToken }),
            viewer,
            Y.el('div', { class: 'card' }, meta(v)));
          });
          return (viewer.yurunaReadyPromise || Promise.resolve()).then(function () {
            window.YurunaFirstUsable.mark('test/extension/stash-service/server/internal/httpsrv/web/stash.html', viewer.yurunaReadyState || 'data');
          });
        });
      });
    }).then(null, function (e) {
      $('detail').className = '';
      msg('error', e.status === 404 ? window.YurunaI18n.t("stash.stash_not_found") : window.YurunaI18n.t("stash.error_value1", {value1: (e.message)}));
      $('detail').textContent = '';
      window.YurunaFirstUsable.mark('test/extension/stash-service/server/internal/httpsrv/web/stash.html', 'error');
    });
  }

  load();
})();
