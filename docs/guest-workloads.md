# Guest Workloads

Optional software workloads installed into a Yuruna guest via
`fetch-and-execute.sh`. See [Yuruna Architecture](architecture.md) for the
guest workload pattern, and each guest folder's `README.md` for which
workloads that guest supports. Kubernetes has its own page
([kubernetes.md](kubernetes.md)).

## Code

Installs Java (JDK), .NET SDK, Git, [Visual Studio Code](https://code.visualstudio.com/),
and PowerShell.

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.code.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.code.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.code.sh` |
| **Windows 11** | `irm "…/guest/windows.11/windows.11.code.ps1$nc" \| iex` (see [Windows 11 ...](../guest/windows.11/README.md)) |

### After install

```
gh auth login
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

Then open VS Code and sign in to each extension that needs it.

## n8n

Installs [n8n](https://n8n.io/) workflow automation.

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.n8n.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.n8n.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.n8n.sh` |

Verify + run:

```
n8n --version
n8n start     # open http://localhost:5678
```

Full docs: [n8n.io/docs](https://docs.n8n.io/).

## OpenClaw

Installs Git, Node.js, and [OpenClaw](https://docs.openclaw.ai/start/getting-started).

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.openclaw.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.openclaw.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.openclaw.sh` |

After reboot, configure:

```
openclaw onboard --install-daemon
```

**Careful: you are about to give AI some privileged access to your accounts!**

![OpenClaw onboarding consent screen — list of accounts and capabilities the agent is about to be granted access to](images/001.openclaw.config.png)

See [Getting Started](https://docs.openclaw.ai/start/getting-started).

## PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.postgresql.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.postgresql.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.postgresql.sh` |

Verify:

```
sudo -u postgres psql -c "SELECT version();"
```

Download guides: [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) ·
[Red Hat](https://www.postgresql.org/download/linux/redhat/).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
