# Ubuntu Desktop Guest

Scripts and tools for Ubuntu Desktop guest environments.

## VM Setup

Create the VM on your host first:

- [macOS UTM host](../host.macos.utm/ubuntu.desktop.guest/README.md)
- [Windows Hyper-V host](../host.windows.hyper-v/ubuntu.desktop.guest/README.md)

## Post-VDE Setup

After your base VM is running, use these scripts to install additional tools and services. Open a terminal in the guest and run the desired commands.

### Update

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.update.bash)"
```

### Available toolsets

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.code.bash)"
```

- [LM Studio](../docs/lmstudio.md) - LM Studio for local AI

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.lmstudio.bash)"
```

- [n8n](../docs/n8n.md) - n8n workflow automation

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.n8n.bash)"
```

- [OpenClaw](../docs/openclaw.md) - Git, Node.js, and the OpenClaw AI agent

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.openclaw.bash)"
```

- [PostgreSQL](../docs/postgresql.md) - PostgreSQL database from the official PGDG repository

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.postgresql.bash)"
```

- [yuruna](../docs/yuruna.md) - All yuruna requirements (Docker, Kubernetes, Helm, OpenTofu, Cloud CLIs, and more)

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.yuruna.bash)"
```
