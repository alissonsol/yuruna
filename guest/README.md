# Guests — workloads that run inside a VM

Each subfolder holds the workload scripts (Code, k8s, n8n, postgresql,
…) that run **inside** a running guest, independent of which host
created the VM.

- [Amazon Linux](amazon.linux/README.md)
- [Ubuntu Desktop](ubuntu.desktop/README.md)
- [Ubuntu Server](ubuntu.server/README.md)
- [Windows 11](windows.11/README.md)

Project-wide architecture: [../CODE.md](../CODE.md). VM provisioning
scripts (per hypervisor): [../host/README.md](../host/README.md).

## Guest workload pattern

Inside a running guest, workloads are installed by fetching and running
one script each. The fetcher honors `YurunaCacheContent`:

```bash
# Linux guests
/automation/fetch-and-execute.sh guest/<name>/<name>.<workload>.sh
```

```powershell
# Windows 11 guest (elevated)
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/<workload>.ps1$nc" | iex
```

Available workloads are listed in each [<name>/README.md](.) and
documented per-workload under [../docs/](../docs/) (see `code.md`,
`k8s.md`, `lmstudio.md`, `n8n.md`, `openclaw.md`, `postgresql.md`).

Back to [[Yuruna](../README.md)]
