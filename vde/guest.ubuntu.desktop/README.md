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
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.update.sh
```

### Available workloads

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

- [LM Studio](../docs/lmstudio.md) - LM Studio for local AI

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.lmstudio.sh
```

- [n8n](../docs/n8n.md) - n8n workflow automation

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.n8n.sh
```

- [OpenClaw](../docs/openclaw.md) - Git, Node.js, and the OpenClaw AI agent

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.openclaw.sh
```

- [PostgreSQL](../docs/postgresql.md) - PostgreSQL database from the official PGDG repository

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.postgresql.sh
```

- [k8s](../docs/k8s.md) - All Kubernetes requirements (Docker, Kubernetes, Helm, OpenTofu, Cloud CLIs, and more)

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.k8s.sh
```

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
