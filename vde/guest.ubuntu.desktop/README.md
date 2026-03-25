# Ubuntu Desktop Guest - Workloads

Workload scripts and tools for Ubuntu Desktop guests.

## VM Setup

Create the guest VM on your host first:

- [macOS UTM host](../host.macos.utm/guest.ubuntu.desktop/README.md)
- [Windows Hyper-V host](../host.windows.hyper-v/guest.ubuntu.desktop/README.md)

## Post-VDE Setup

After your base VM is running, use these instructions to install workloads. Open a terminal in the guest and run the command for each desired workload.

### Update

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.update.sh?nocache=$(date +%s)")"
```

### Available workloads

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh?nocache=$(date +%s)")"
```

- [LM Studio](../docs/lmstudio.md) - LM Studio for local AI

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.lmstudio.sh?nocache=$(date +%s)")"
```

- [n8n](../docs/n8n.md) - n8n workflow automation

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.n8n.sh?nocache=$(date +%s)")"
```

- [OpenClaw](../docs/openclaw.md) - Git, Node.js, and the OpenClaw AI agent

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.openclaw.sh?nocache=$(date +%s)")"
```

- [PostgreSQL](../docs/postgresql.md) - PostgreSQL database from the official PGDG repository

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.postgresql.sh?nocache=$(date +%s)")"
```

- [k8s](../docs/k8s.md) - All Kubernetes requirements (Docker, Kubernetes, Helm, OpenTofu, Cloud CLIs, and more)

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.k8s.sh?nocache=$(date +%s)")"
```

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
