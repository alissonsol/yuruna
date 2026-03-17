# Amazon Linux Guest

Scripts and tools for Amazon Linux guest environments.

## VM Setup

Create the VM on your host first:

- [macOS UTM host](../host.macos.utm/guest.amazon.linux/README.md)
- [Windows Hyper-V host](../host.windows.hyper-v/guest.amazon.linux/README.md)

## Post-VDE Setup

After your base VM is running, use these scripts to install additional tools and services. Open a terminal in the guest and run the desired commands.

### Update

```bash
sudo bash /amazon.linux.update.bash
```

### Available toolsets

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.code.bash)"
```

- [n8n](../docs/n8n.md) - n8n workflow automation

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.n8n.bash)"
```

- [OpenClaw](../docs/openclaw.md) - Git, Node.js, and the OpenClaw AI agent

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.openclaw.bash)"
```

- [PostgreSQL](../docs/postgresql.md) - PostgreSQL database from the official PGDG repository

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.postgresql.bash)"
```

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).
