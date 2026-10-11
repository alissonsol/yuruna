# Guests -- workloads that run inside a VM

Each subfolder holds the workload scripts (Code, k8s, n8n, postgresql,
...) that run **inside** a running guest, independent of which host
created the VM.

- [Amazon Linux 2023](amazon.linux.2023/README.md)
- [macOS 26](macos.26/README.md) -- Apple Silicon only; Setup Assistant not yet automated
- [Ubuntu Server 24.04](ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](ubuntu.server.26/README.md)
- [Windows 11](windows.11/README.md)

Project-wide architecture: [Yuruna Architecture](../docs/architecture.md). VM provisioning
scripts (per hypervisor): [Hosts -- ...](../host/README.md).

## Guest workload pattern

Workloads are installed by fetching and running one script each. The
fetcher honors `YurunaCacheContent`:

```
# Linux guests (E_SHA: the script's SHA-256, see below)
E_SHA=<sha256> /usr/local/lib/yuruna/fetch-and-execute.sh guest/<name>/<name>.<workload>.sh
```

```
# Windows 11 guest (elevated)
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/windows.11.<workload>.ps1$nc" | iex
```

Ubuntu 24 and 26 share the update, code, n8n, openclaw, and PostgreSQL
implementations in `guest/shared/`. Their release entrypoints verify a pinned
SHA-256 before running a local body or delegate to the installed fetcher with that
digest. `tools/Sync-GuestWorkflows.py` reads `VERSION` and regenerates the
entrypoints after a shared body or version stamp changes; the pre-commit hook
runs it and stages the ten entrypoints automatically. Run it directly when
working outside the hook; `--check` detects stale wrappers. The fetcher
preserves script arguments. Existing baked retry-library fallbacks remain in
the shared bodies.

Available workloads are listed in each guest folder's `README.md` (linked
above) and documented per-workload under [../docs/](../docs/) -- see [Guest
workloads](../docs/guest-image-setup.md#guest-workloads) for
code/n8n/openclaw/postgresql, and [kubernetes.md](../docs/kubernetes.md).

### Supplying the digest by hand

The Linux fetcher hands whatever it downloads straight to `bash`. The download
comes from the host status service over plain HTTP, or from GitHub when the
host is unreachable, so the bytes alone prove nothing: the fetcher refuses to
run a script unless it is also given that script's expected SHA-256 through a
channel other than the download. Test cycles supply the digest themselves; a
hand run passes it as `E_SHA`, taken from a checkout you trust and not from the
guest. When no digest can be obtained (manual recovery), prefix
`EXEC_ALLOW_UNVERIFIED=1` instead: the script then runs unchecked, under a
warning banner that names the file. The override never excuses a wrong digest,
and it is ignored when the harness sets `EXEC_REQUIRE_SHA256=1`.

```
# On a machine you trust, in a checkout of the commit you reviewed:
sha256sum guest/ubuntu.server.24/ubuntu.server.24.code.sh   # macOS: shasum -a 256 <file>
(Get-FileHash guest/ubuntu.server.24/ubuntu.server.24.code.sh).Hash   # PowerShell

# In the guest, with the digest printed above (upper or lower case):
E_SHA=<digest> /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.code.sh

# Under sudo, the assignment goes after "sudo" (sudo clears the environment otherwise):
sudo E_SHA=<digest> /usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.update.sh

# Last resort, no digest obtainable:
EXEC_ALLOW_UNVERIFIED=1 /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.update.sh
```

- Hash the file the guest will actually fetch: your working tree while the host
  status service is serving it, or the commit named by `E_FB_REF` when the
  guest falls back to GitHub (`git show <commit>:<path> | sha256sum`). Pin that
  fallback with `E_FB_REPO=<owner>/<repo> E_FB_REF=<full commit hash>`; without
  them the guest uses the commit baked into `/etc/yuruna/host.env`.
- `E_RETRY_SHA` is needed only on a guest that lacks
  `/usr/local/lib/yuruna/yuruna-retry.sh`, which every Yuruna-provisioned guest
  has. Without it that library is not installed.
- For an Ubuntu entrypoint in `guest/ubuntu.server.*/`, pass the digest of the
  entrypoint file itself; it then supplies the pinned digest of the shared
  workflow it delegates to, so no second digest is needed.
- An update script needs no digest when it is piped over SSH from your checkout
  instead (the ad hoc recipe in
  [guest-image-setup.md](../docs/guest-image-setup.md)): the bytes never take the
  fetch path. An Ubuntu entrypoint piped that way still fetches its shared
  workflow, under its own pinned digest.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.11

Back to [Yuruna](../README.md)
