# Guests — workloads that run inside a VM

Each subfolder holds the workload scripts (Code, k8s, n8n, postgresql,
…) that run **inside** a running guest, independent of which host
created the VM.

- [Amazon Linux 2023](amazon.linux.2023/README.md)
- [macOS 26](macos.26/README.md) — Apple Silicon only; Setup Assistant not yet automated
- [Ubuntu Server 24.04](ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](ubuntu.server.26/README.md)
- [Windows 11](windows.11/README.md)

Project-wide architecture: [Yuruna Architecture](../docs/architecture.md). VM provisioning
scripts (per hypervisor): [Hosts — ...](../host/README.md).

## Guest workload pattern

Inside a running guest, workloads are installed by fetching and running
one script each. The fetcher honors `YurunaCacheContent`:

```
# Linux guests
/usr/local/lib/yuruna/fetch-and-execute.sh guest/<name>/<name>.<workload>.sh
```

```
# Windows 11 guest (elevated)
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/<workload>.ps1$nc" | iex
```

Available workloads are listed in each guest folder's `README.md`
(e.g. [Amazon Linux 2023](amazon.linux.2023/README.md),
[Ubuntu Server 24.04](ubuntu.server.24/README.md),
[Ubuntu Server 26.04](ubuntu.server.26/README.md),
[Windows 11](windows.11/README.md)) and documented per-workload under
[../docs/](../docs/) (see `code.md`, `kubernetes.md`, `n8n.md`,
`openclaw.md`, `postgresql.md`).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
