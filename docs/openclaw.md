# OpenClaw

Installs Git, Node.js, and [OpenClaw](https://docs.openclaw.ai/start/getting-started).

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/automation/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.openclaw.sh` |
| **Ubuntu Server 24.04** | `/automation/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.openclaw.sh` |
| **Ubuntu Server 26.04** | `/automation/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.openclaw.sh` |

After reboot, configure:

```bash
openclaw onboard --install-daemon
```

**Careful: you are about to give AI some privileged access to your accounts!**

![](images/001.openclaw.config.png)

See [Getting Started](https://docs.openclaw.ai/start/getting-started).

Back to [Amazon Linux 2023 ...](../guest/amazon.linux.2023/README.md) ·
[Ubuntu Server 24.04 ...](../guest/ubuntu.server.24/README.md) ·
[Ubuntu Server 26.04 ...](../guest/ubuntu.server.26/README.md) ·
[Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
