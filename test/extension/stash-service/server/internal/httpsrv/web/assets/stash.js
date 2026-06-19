// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Stash detail view (stash-service-ui.md §6, §7, §8). Renders by content
// class, always offers download, deletes only local-host stashes.

(function () {
  const TEXT_PREVIEW_CAP = 1024 * 1024; // fallback if the server omits inlineTextCap (§6.2)
  const state = { inlineTextCap: 0 };
  const $ = (id) => document.getElementById(id);

  // Parse /s/<host>/<y>/<m>/<d>/<id> (the canonical permalink, §4.4). The
  // local short alias /s/<y>/<m>/<d>/<id> also resolves: it produces a
  // 4-segment API path that the server's alias route maps to this host.
  function apiPath() {
    const parts = location.pathname.split('/').filter(Boolean); // [s, ...]
    return '/api/stashes/' + parts.slice(1).join('/');
  }

  function msg(kind, text) {
    $('msg').replaceChildren(Y.el('div', { class: 'notice ' + kind, text }));
  }

  function meta(v) {
    const dl = Y.el('dl', { class: 'kv' });
    const add = (k, val) => { dl.append(Y.el('dt', { text: k }), Y.el('dd', { text: val })); };
    add('ID', v.id);
    add('Name', v.originalFilename || '(unnamed)');
    add('Host', v.local ? v.hostId + '  (this host)' : v.hostId);
    add('Type', (v.mimeType || v.contentClass) + (v.typeLabel ? '  [' + v.typeLabel + ']' : ''));
    add('Size', Y.humanSize(v.sizeBytes));
    add('User', v.username);
    add('Source', v.source || 'scp');
    add('Status', v.status);
    if (v.pathMetadata) add('SCP path', v.pathMetadata);
    add('Created', Y.fmtDate(v.createdAt));
    if (v.receivedAt) add('Received', Y.fmtDate(v.receivedAt));
    if (v.local) add('Short link', location.origin + '/' + v.id);
    add('Permalink', location.origin + v.permalink);
    return dl;
  }

  function actions(v) {
    const box = Y.el('div', { class: 'actions' });
    box.append(Y.el('a', { class: 'btn primary', href: Y.downloadURL(v), download: v.originalFilename || v.id, text: 'Download' }));
    if (v.local) {
      box.append(Y.el('button', { class: 'btn destructive', onclick: () => confirmDelete(v) }, 'Delete'));
    } else {
      const btn = Y.el('button', { class: 'btn destructive', disabled: 'disabled', title: 'Owned by host ' + v.hostId }, 'Delete');
      box.append(btn);
      const where = Y.el('span', { class: 'muted' }, ' Owned by host ');
      where.append(Y.el('span', { class: 'mono', text: Y.shortHost(v.hostId) }));
      if (v.remoteStashUrl) {
        where.append(' — ', Y.el('a', { href: v.remoteStashUrl, text: 'open on that host to delete' }));
      } else {
        where.append('; delete it from that host’s own stash UI.');
      }
      box.append(where);
    }
    return box;
  }

  async function confirmDelete(v) {
    if (!confirm('Delete stash ' + v.id + ' (' + (v.originalFilename || 'unnamed') + ', ' + Y.humanSize(v.sizeBytes) + ') on this host? This cannot be undone.')) return;
    try {
      await Y.api(apiPath(), { method: 'DELETE' });
      location.href = '/';
    } catch (e) {
      msg('error', 'Delete failed: ' + e.message);
    }
  }

  async function renderViewer(v) {
    const wrap = Y.el('div', { class: 'card' });
    if (v.status === 'pending') { wrap.append(Y.el('div', { class: 'muted', text: 'Still receiving — no preview yet.' })); return wrap; }
    if (v.status === 'partial') { wrap.append(Y.el('div', { class: 'muted', text: 'Incomplete upload — partial bytes available via Download.' })); return wrap; }
    if (v.status === 'truncated') wrap.append(Y.el('div', { class: 'notice warn', text: 'Truncated at the 100 MB cap — Download serves the capped artifact.' }));

    const raw = Y.rawURL(v);
    switch (v.contentClass) {
      case 'image':
        wrap.append(Y.el('img', { class: 'viewer-img', src: raw, alt: v.originalFilename || v.id }));
        break;
      case 'pdf':
        wrap.append(Y.el('embed', { class: 'viewer-frame', src: raw, type: 'application/pdf' }));
        break;
      case 'audio':
        wrap.append(Y.el('audio', { class: 'viewer-av', controls: 'controls', src: raw }));
        break;
      case 'video':
        wrap.append(Y.el('video', { class: 'viewer-av', controls: 'controls', src: raw }));
        break;
      case 'text':
        await renderText(wrap, raw);
        break;
      case 'archive':
        await renderArchive(wrap, v);
        break;
      default:
        wrap.append(Y.el('div', { class: 'muted', text: 'No inline preview for this type (download to view).' }));
    }
    return wrap;
  }

  async function renderText(wrap, raw) {
    try {
      const res = await fetch(raw);
      if (!res.ok) {
        wrap.append(Y.el('div', { class: 'notice error', text: 'Could not load text: HTTP ' + res.status }));
        return;
      }
      const buf = await res.text();
      let body = buf, truncated = false;
      const cap = state.inlineTextCap || TEXT_PREVIEW_CAP;
      if (body.length > cap) { body = body.slice(0, cap); truncated = true; }
      const pre = Y.el('pre', { class: 'viewer wrap' });
      pre.textContent = body; // textContent: never interpret as HTML (§7.4)
      if (truncated) wrap.append(Y.el('div', { class: 'notice warn', text: 'Preview truncated — Download for the full content.' }));
      wrap.append(pre);
    } catch (e) {
      wrap.append(Y.el('div', { class: 'notice error', text: 'Could not load text: ' + e.message }));
    }
  }

  async function renderArchive(wrap, v) {
    wrap.append(Y.el('div', { class: 'muted', text: 'Archive (' + Y.humanSize(v.sizeBytes) + ') — contents:' }));
    try {
      const data = await Y.api(apiPath() + '/archive');
      const tbl = Y.el('table', { class: 'stashes' });
      const tb = Y.el('tbody');
      for (const e of data.entries) {
        tb.append(Y.el('tr', {},
          Y.el('td', { class: 'mono', text: e.name }),
          Y.el('td', { class: 'num', text: e.dir ? '' : Y.humanSize(e.size) })));
      }
      tbl.append(tb);
      wrap.append(tbl);
    } catch (e) {
      wrap.append(Y.el('div', { class: 'notice error', text: 'Could not list archive: ' + e.message }));
    }
  }

  async function load() {
    try {
      const data = await Y.api(apiPath());
      const v = data.stash;
      state.inlineTextCap = data.inlineTextCap || 0;
      document.title = (v.originalFilename || v.id) + ' · Yuruna Stash';
      const detail = $('detail');
      detail.className = '';
      detail.replaceChildren(
        Y.el('h2', { text: v.originalFilename || v.id }),
        actions(v),
        await renderViewer(v),
        Y.el('div', { class: 'card' }, meta(v)),
      );
    } catch (e) {
      $('detail').className = '';
      msg('error', e.status === 404 ? 'Stash not found.' : ('Error: ' + e.message));
      $('detail').textContent = '';
    }
  }

  load();
})();
