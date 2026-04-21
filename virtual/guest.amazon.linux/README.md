# Amazon Linux Guest - Workloads

Workload scripts and tools for Amazon Linux guests.

## VM Setup

Create the guest VM on your host first:

- [macOS UTM host](../host.macos.utm/guest.amazon.linux/README.md)
- [Windows Hyper-V host](../host.windows.hyper-v/guest.amazon.linux/README.md)

## Post-VDE Setup

After your base VM is running, use these instructions to install workloads. Open a terminal in the guest and run the command for each desired workload.

### Update

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.update.sh
```

### Available workloads

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.code.sh
```

- [n8n](../docs/n8n.md) - n8n workflow automation

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.n8n.sh
```

- [OpenClaw](../docs/openclaw.md) - Git, Node.js, and the OpenClaw AI agent

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.openclaw.sh
```

- [PostgreSQL](../docs/postgresql.md) - PostgreSQL database from the official PGDG repository

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.postgresql.sh
```

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
