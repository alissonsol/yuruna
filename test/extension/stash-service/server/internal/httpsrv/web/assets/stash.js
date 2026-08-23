// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Stash detail view. Renders by content class, always offers download, and
// deletes any stash once this browser is through the lab-token gate.

(function () {
  var TEXT_PREVIEW_CAP = 1024 * 1024; // fallback if the server omits inlineTextCap (section 6.2)
  var state = { inlineTextCap: 0 };
  function $(id) { return document.getElementById(id); }

  // Parse /s/<host>/<y>/<m>/<d>/<id> (the canonical permalink, section 4.4). The
  // local short alias /s/<y>/<m>/<d>/<id> also resolves: it produces a
  // 4-segment API path that the server's alias route maps to this host.
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
    add('Name', v.originalFilename || '(unnamed)');
    add('Host', v.local ? Y.guid(v.hostId) + '  (this host)' : Y.guid(v.hostId));
    add('Type', (v.mimeType || v.contentClass) + (v.typeLabel ? '  [' + v.typeLabel + ']' : ''));
    add('Size', Y.humanSize(v.sizeBytes));
    add('User', v.username);
    add('Source', v.source || 'scp');
    add('Status', v.status);
    if (v.pathMetadata) { add('SCP path', v.pathMetadata); }
    add('Created', Y.fmtDate(v.createdAt));
    if (v.receivedAt) { add('Received', Y.fmtDate(v.receivedAt)); }
    if (v.local) { add('Short link', window.location.origin + '/' + v.id); }
    add('Permalink', window.location.origin + v.permalink);
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
    Y.append(box, Y.el('a', { class: 'btn primary', href: Y.downloadURL(v), download: v.originalFilename || v.id, text: 'Download' }));
    if (gate.canDelete) {
      Y.append(box, Y.el('button', { class: 'btn destructive', onclick: function () { confirmDelete(v); } }, 'Delete'));
    } else {
      Y.append(box, Y.el('button', { class: 'btn destructive', disabled: 'disabled', title: 'Unlock actions to delete' }, 'Delete'));
      Y.append(box, Y.el('span', { class: 'muted' }, gate.labToken
        ? ' Locked -- unlock actions with the Lab token above, or open this page from the Yuruna hosts dashboard.'
        : ' Delete is unavailable: this service has no pool aggregator configured, so no Lab token can be checked.'));
    }
    if (!v.local) {
      var where = Y.el('span', { class: 'muted' }, ' Received by host ');
      Y.append(where, Y.el('span', { class: 'mono', text: Y.shortHost(v.hostId), title: Y.guid(v.hostId) }));
      if (v.remoteStashUrl) {
        Y.append(where, ' -- ', Y.el('a', { href: v.remoteStashUrl, text: 'open on that host' }));
      }
      Y.append(box, where);
    }
    return box;
  }

  function confirmDelete(v) {
    if (!window.confirm('Delete stash ' + v.id + ' (' + (v.originalFilename || 'unnamed') + ', ' + Y.humanSize(v.sizeBytes) + ')? This cannot be undone.')) { return Promise.resolve(); }
    // Same barrier as the list page: from here on this page is describing a
    // stash that is going away, and its Download button would fail for a reason
    // that looks like the page's fault.
    var done = Y.block('Deleting...');
    return Y.api(apiPath(), { method: 'DELETE' }).then(function () {
      // Deliberately NOT released here: the browser is leaving, and a page that
      // became clickable again while the next one loads would reopen the very
      // gap this closes. The navigation takes the barrier with it.
      // Route even this static destination through the shared safeUrl gate so
      // every navigation in the UI passes one same-origin check.
      window.location.href = Y.safeUrl('/') || '/';
    }, function (e) {
      done();
      msg('error', 'Delete failed: ' + e.message);
    });
  }

  // Resolves with the built card. The two classes that have to fetch more
  // (text, archive) are why this answers a promise at all; every other class is
  // ready the moment the element exists.
  function renderViewer(v) {
    var wrap = Y.el('div', { class: 'card' });
    if (v.status === 'pending') {
      Y.append(wrap, Y.el('div', { class: 'muted', text: 'Still receiving -- no preview yet.' }));
      return Promise.resolve(wrap);
    }
    if (v.status === 'partial') {
      Y.append(wrap, Y.el('div', { class: 'muted', text: 'Incomplete upload -- partial bytes available via Download.' }));
      return Promise.resolve(wrap);
    }
    if (v.status === 'truncated') {
      Y.append(wrap, Y.el('div', { class: 'notice warn', text: 'Truncated at the 100 MB cap -- Download serves the capped artifact.' }));
    }

    var raw = Y.rawURL(v);
    switch (v.contentClass) {
      case 'image':
        Y.append(wrap, Y.el('img', { class: 'viewer-img', src: raw, alt: v.originalFilename || v.id }));
        break;
      case 'pdf':
        Y.append(wrap, Y.el('embed', { class: 'viewer-frame', src: raw, type: 'application/pdf', title: (v.originalFilename || v.id) + ' (PDF preview)' }));
        // Neither iOS Safari nor Android Chrome renders a PDF inside <embed>;
        // both paint an empty frame with no hint that anything is wrong.
        // Desktop Firefox/Chrome do render it, and then this link is merely
        // redundant.
        Y.append(wrap, Y.el('p', { class: 'notice' },
          Y.el('a', { href: raw, target: '_blank', rel: 'noopener', text: 'Open PDF' })));
        break;
      case 'audio':
        Y.append(wrap, Y.el('audio', { class: 'viewer-av', controls: 'controls', src: raw }));
        break;
      case 'video':
        Y.append(wrap, Y.el('video', { class: 'viewer-av', controls: 'controls', src: raw }));
        break;
      case 'text':
        return renderText(wrap, raw).then(function () { return wrap; });
      case 'archive':
        return renderArchive(wrap, v).then(function () { return wrap; });
      default:
        Y.append(wrap, Y.el('div', { class: 'muted', text: 'No inline preview for this type (download to view).' }));
    }
    return Promise.resolve(wrap);
  }

  function renderText(wrap, raw) {
    return window.fetch(raw).then(function (res) {
      if (!res.ok) {
        Y.append(wrap, Y.el('div', { class: 'notice error', text: 'Could not load text: HTTP ' + res.status }));
        return null;
      }
      return res.text().then(function (buf) {
        var body = buf;
        var truncated = false;
        var cap = state.inlineTextCap || TEXT_PREVIEW_CAP;
        if (body.length > cap) { body = body.slice(0, cap); truncated = true; }
        var pre = Y.el('pre', { class: 'viewer wrap', tabindex: '0', role: 'region', 'aria-label': 'Stash text preview' });
        pre.textContent = body; // textContent: never interpret as HTML (section 7.4)
        if (truncated) { Y.append(wrap, Y.el('div', { class: 'notice warn', text: 'Preview truncated -- Download for the full content.' })); }
        Y.append(wrap, pre);
        return null;
      });
    }, function (e) {
      Y.append(wrap, Y.el('div', { class: 'notice error', text: 'Could not load text: ' + e.message }));
    });
  }

  function renderArchive(wrap, v) {
    Y.append(wrap, Y.el('div', { class: 'muted', text: 'Archive (' + Y.humanSize(v.sizeBytes) + ') -- contents:' }));
    return Y.api(apiPath() + '/archive').then(function (data) {
      var tbl = Y.el('table', { class: 'stashes' });
      Y.append(tbl, Y.el('caption', { class: 'sr-only', text: 'Archive contents' }));
      var th = Y.el('thead');
      Y.append(th, Y.el('tr', {},
        Y.el('th', { scope: 'col', text: 'Name' }),
        Y.el('th', { scope: 'col', class: 'num', text: 'Size' })));
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
      Y.append(wrap, Y.el('div', { class: 'notice error', text: 'Could not list archive: ' + e.message }));
    });
  }

  function load() {
    // Spends a control proof carried in from the dashboard before reading the
    // gate, so a page opened through that link renders with Delete live.
    // The failure handler is a SEPARATE link in the chain, not this .then's
    // second argument: a rejection raised inside the success handler below --
    // the stash read 404ing, most of all -- would never reach a handler
    // installed alongside it.
    return Y.initUnlock(load).then(function (sess) {
      return Y.api(apiPath()).then(function (data) {
        var v = data.stash;
        state.inlineTextCap = data.inlineTextCap || 0;
        return renderViewer(v).then(function (viewer) {
          // Page first, service second, so a row of open tabs stays tellable
          // apart.
          document.title = (v.originalFilename || v.id) + ' -- Yuruna Stash';
          var detail = $('detail');
          detail.className = '';
          Y.replace(detail,
            Y.el('h1', { text: v.originalFilename || v.id }),
            actions(v, { canDelete: sess.authed, labToken: sess.labToken }),
            viewer,
            Y.el('div', { class: 'card' }, meta(v)));
        });
      });
    }).then(null, function (e) {
      $('detail').className = '';
      msg('error', e.status === 404 ? 'Stash not found.' : ('Error: ' + e.message));
      $('detail').textContent = '';
    });
  }

  load();
})();
