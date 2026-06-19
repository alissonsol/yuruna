# OpenClaw

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

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../README.md)
