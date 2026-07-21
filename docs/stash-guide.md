# Yuruna Stash — user guide

The **stash** is a shared drop box for files and snippets. You put content
in from the command line (`scp`) or from the browser, then browse, view,
download, or delete it in the web UI. A stash is the same object however it
was created.

> **Access.** The stash runs on a trusted network with **no login** —
> anyone who can reach it can add, read, and delete stashes. Don't put
> secrets in it. Each uploaded file is capped at **100 MB**.

Two addresses for the same VM:

- **Web UI:** `http://<vm-ip>/`
- **Uploads (scp/sftp):** `<vm-ip>` port 22

---

## Stash from the command line

Use a normal `scp`. **Any** username works and **no** password or key is
needed — the username is just recorded as a label.

```bash
# One file
scp report.pdf me@<vm-ip>:/anything

# A whole folder (stored as one .zip)
scp -r ./logs me@<vm-ip>:/anything
```

- The path after `:` is only saved as a note; it is not a real location.
- Modern `scp` stores **one stash per file**.
- To group several files into **one** stash (a `.zip`) in a single command,
  use legacy mode with `-O`:

  ```bash
  scp -O a.txt b.txt me@<vm-ip>:/anything   # → one .zip stash
  ```

**Finding the ID.** With `-O`, `scp` prints the new stash's ID to your
terminal:

```
YURUNA-STASH-ID: a1b2
```

Without `-O` the ID isn't printed — just open the web UI; your upload is at
the top of the list.

`sftp` works too (it's what modern `scp` uses under the hood). Downloads
over scp/sftp are not allowed — the command line is for **putting in**;
take things out from the UI.

---

## Stash from the browser

Open `http://<vm-ip>/` and click **+ New stash**:

- **Paste text** — type or paste into the box. Optionally set a
  *title/filename* (e.g. `notes.md`, which also picks the file type) and an
  *author*.
- **Upload file(s)** — choose one or more files. Several files become one
  `.zip` stash, exactly like `scp -O`.

Click **Create** and you land on the new stash.

---

## Find and view

The home page lists recent stashes from **every** host in the pool, newest
first. Each row shows the type, ID, name, owning host, user, size, and date.

- **Search** by ID, filename, user, or path in the search box.
- **Filter** by type (text / image / PDF / …) or by host.
- **Refresh** rescans the share for other hosts' newest stashes.
- **Click a row** to open it.

On a stash's page:

- **Text** is shown inline (large text is previewed, then truncated —
  download for the whole thing).
- **Images, PDFs, audio, and video** play/render inline.
- **Archives** show their file listing.
- Anything else is download-only.

---

## Short links

Every stash has a short link — just the host and its 4-character ID:

```
http://<vm-ip>/h775
```

Open or share that and it jumps straight to the stash (`/v/h775` works
too). The stash's page shows its short link under the details.

## Download

Every stash has a **Download** button that always gives you the complete
file (or the `.zip` for a multi-file / folder stash) — regardless of type
or status.

---

## Delete

Open the stash and click **Delete** (you'll be asked to confirm).
**Deletion is permanent.**

You can only delete stashes **owned by the host you're viewing**. A stash
from another host shows a **disabled** Delete and names its owner; open that
host's stash UI to delete it there.

---

## Good to know

- **Same object either way.** A pasted stash and an `scp` upload are
  identical — same ID format, same storage, same listing.
- **Durable.** Stashes live on shared pool storage, so they survive a VM
  restart or rebuild.
- **Type detection** is automatic from the content, so a file's type is
  recognized even without an extension.

For how the service is built, see the design specs:
[Stash Service](design/stash-service.md) and
[Stash Service UI](design/stash-service-ui.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
