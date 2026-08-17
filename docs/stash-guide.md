# Yuruna Stash — user guide

The **stash** is a shared drop box for files and snippets. You put content
in from the command line (`scp`) or from the browser, then browse, view,
download, or delete it in the web UI.

> **Access.** The stash runs on a trusted network with **no login** —
> anyone who can reach it can add and read stashes. Don't put secrets in
> it. Deleting is the exception: it asks for the dashboard's Lab token
> ([below](#delete)). Each uploaded file is capped at **100 MB**.

Two addresses for the same VM:

- **Web UI:** `http://<vm-ip>/`
- **Uploads (scp/sftp):** `<vm-ip>` port 22

---

## Stash from the command line

Use a normal `scp`. **Any** username works and **no** password or key is
needed — the username is recorded only as a label.

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

Without `-O` the ID isn't printed — open the web UI; your upload is at the
top of the list.

`sftp` works too (it's what modern `scp` uses under the hood). Downloads
over scp/sftp are not allowed: the command line is for **putting in**;
take things out from the UI.

---

## Stash from the browser

Open `http://<vm-ip>/` and click **+ New stash**:

- **Paste text** — type or paste into the box. Optionally set a
  *title/filename* (e.g. `notes.md`, which also picks the file type) and an
  *author*.
- **Upload file(s)** — choose one or more files. Several files become one
  `.zip` stash, like `scp -O`.

Click **Create** and you land on the new stash.

---

## Find and view

The home page lists recent stashes from **every** host in the pool, newest
first. Each row shows the type, ID, name, owning host, user, size, and date.

- **Search** by ID, filename, user, or path in the search box.
- **Filter** by type (text / image / PDF / …) or by host.
- **Sort** by clicking a column heading; click it again to reverse it. An
  arrow marks the column in use. Size and date open with the largest and the
  newest first, the rest from the top of the alphabet.
- **Refresh** rescans the share for other hosts' newest stashes.
- **Click a row** to open it.

Sorting covers **everything that matches**, not just the rows on screen — sort
by size and the largest stash in the pool comes to the top even if the list is
showing the first fifty of six hundred. Searching or filtering keeps the order
you chose.

On a stash's page:

- **Text** is shown inline (large text is previewed, then truncated —
  download for the whole thing).
- **Images, PDFs, audio, and video** play/render inline.
- **Archives** show their file listing.
- Anything else is download-only.

---

## Short links

Every stash has a short link — the host and its 4-character ID:

```
http://<vm-ip>/h775
```

Open or share that and it jumps straight to the stash (`/v/h775` works
too). The stash's page shows its short link under the details.

## Download

Every stash has a **Download** button that always gives you the complete
file (or the `.zip` for a multi-file / folder stash), regardless of type
or status.

---

## Delete

Open the stash and click **Delete** (you'll be asked to confirm).
**Deletion is permanent.**

From the **Stashes** list you can also delete without opening anything:

- Each row has its own **Delete** button. It deletes that stash
  **straight away, with no confirmation**, and the row disappears — the
  rest of the page stays as it was.
- Tick the checkboxes on the rows you want (or **All**, which ticks every
  row on screen) and use **Delete selected** above the table. That one
  asks you to confirm, then deletes them all and reloads the list.

While a delete runs, the page is covered and shows **Deleting…** — nothing on
it can be clicked until the new list is up. The rows still on screen during
that moment are the old ones, and some of them no longer exist; opening or
downloading one would fail for a reason that has nothing to do with you.

Deleting needs the actions on the page **unlocked**. Anyone on the lab network
can browse and create; deleting asks for the 6-character **Lab token** from the
Yuruna hosts dashboard. Until then the page says so and shows no Delete control
at all, so there is nothing to press that would be refused.

**Opening the stash from the dashboard skips the code.** Click the stash
service in the dashboard's *Extension hosts* table and the page arrives already
unlocked — you only type the Lab token when you got here some other way. Either
way the session lasts a week on that browser.

Because the dashboard is what checks the code, **unlocking** depends on it being
reachable. While it is down, unlocking answers that the code *could not be
checked* — the code is fine, the check isn't. A browser that unlocked earlier is
unaffected and can still delete; it is new unlocks that cannot happen, from any
machine, the stash VM included. Browsing and creating never need the dashboard
at all.

Restarting the stash service ends every session, so a restart while the
dashboard is unreachable leaves nobody able to unlock until it comes back.

You can delete stashes from **any host in the pool**, not only the one you are
viewing. The stash service writes to the whole shared stash folder, so a stash
another host received is removed just the same, and its disk space comes back
immediately. That host's own list catches up on its own within a minute or so —
it does not have to be running, which is what makes it possible to clean up
after a machine that is switched off or gone for good.

The same catch-up covers stashes deleted **by hand on the NAS**: the row
disappears from the listing once the service notices the files are gone. You
should not need to do that any more, though — that is what this page is for.

---

## Good to know

- **Same object either way.** A pasted stash and an `scp` upload are
  identical — same ID format, same storage, same listing.
- **Durable.** Stashes live on shared pool storage, so they survive a VM
  restart or rebuild.
- **Type detection** is automatic from the content, so a file's type is
  recognized without an extension.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.16

Back to [Yuruna](../README.md)
