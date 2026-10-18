# Digest extension

SHA-256 values a sequence step carries to a guest in its launch command, so a
guest script can verify what it downloads before it extracts, installs or runs
it.

## Why this exists

`fetch-and-execute.sh` verifies the script it launches against a digest the host
**types into the command** (over SSH or the console), never against anything the
HTTP download itself carries. That protects the launched script and nothing it
fetches afterwards. A script that downloads an archive and extracts it, feeds a
SQL file to a database, or installs a binary is trusting a plain HTTP answer from
a status service on a LAN: whoever can answer that request decides the bytes.

The fix is the same channel. The sequence puts the digests of those nested inputs
in the command text, computed on the host at step time, and the guest script
compares what it downloaded to them **before** using it. The digest is the trust
boundary; the transport is not. The status listener offers HTTP only, so there
is no transport upgrade to prefer.

```yaml
command: "AMISAD_SCHEMA_SHA256='${ext:digest.GetFileSha256(project/poc/db/schema.sql)}' /usr/local/lib/yuruna/fetch-and-execute.sh project/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.db.sh"
```

## Methods

| Expression | Value |
| --- | --- |
| `${ext:digest.GetFileSha256(<path>)}` | SHA-256 of a file under the checkout root, the base the status service serves at `/yuruna-repo/`. Byte for byte, line endings included. Only a plain relative path is accepted: no leading slash, `..`, wildcard or colon. |
| `${ext:digest.GetArchiveSha256(project)}` / `(framework)` | SHA-256 of the committed-content tarball the status service serves at `/yuruna-project-archive.tar.gz` / `/yuruna-archive.tar.gz`. |
| `${ext:digest.GetPublishedSha256(<name>)}` | The digest a `callExtension` step published under `<name>`. |
| `callExtension` `digest.PublishGuestFileSha256` | Reads `sha256sum` of a file inside a guest over the harness SSH channel and records it under `<name>` in `<runtime>/digest/<name>.json`. Arguments: `name`, `vmName`, `path` (absolute, one `*` allowed, must match exactly one file), `user`, `guestKey`. |

The readers used inside `${ext:...}` **warn and return an empty string** instead
of throwing, the way `stash-service.ResolveHost` does. An empty value reaches the
guest as an empty variable, which a verifying guest refuses; a plausible but wrong
value never gets the chance to appear. `PublishGuestFileSha256` runs as a step and
throws, which fails the step, and a failed read leaves the previous record in place
so a stale digest is never mistaken for the new artifact's.

## The archive digest

The tarball is cut on demand from the clone's HEAD, so there is no file to hash.
`GetArchiveSha256` therefore asks the status service for it over loopback and
hashes what comes back. That removes any second implementation of how the tarball
is cut that could drift from the one that serves it. Two properties make the later
guest download match:

- The service keeps what it cut, keyed by commit, and answers the guest from that.
- A re-cut of one commit is byte-identical anyway (a restarted service, an
  evicted entry): tar entries carry the commit time and fixed ownership, and the
  gzip header carries no timestamp.
  `test/modules/Test.StatusArchiveProvenance.Tests.ps1` holds that property.

If the clone's HEAD moves between the hash and the download (a `git pull` in
`project/` during a step), the guest's check refuses the download and the step is
re-run, which re-hashes. That is the intended failure: the alternative is a guest
that extracts a tree nobody hashed.

## Publishing a digest for an artifact one guest produces and another downloads

An artifact built in one guest and fetched by another through a shared service
(a stash) has no copy on the host. The producing guest is the authority on its
digest, so the host asks it right after the step that produced the file:

```yaml
- action: callExtension
  method: digest.PublishGuestFileSha256
  args:
    name: amisad-binaries
    vmName: "${vmName}"
    user: "${username}"
    path: "/tmp/amisad-*-binaries.tgz"
```

The consumer's launch command then carries
`${ext:digest.GetPublishedSha256(amisad-binaries)}`. Whatever happens to the
bytes in between, whether a tampered share or a truncated upload, the consumer's
check against this digest catches it.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.14

Back to [Extensions API](../../../docs/extensions-api.md)
