# OpenClaw

Installs Git, Node.js, and [OpenClaw](https://docs.openclaw.ai/start/getting-started).

| Guest | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.openclaw.sh` |
| **Ubuntu Desktop** | `ubuntu.desktop.openclaw.sh` |

**Amazon Linux**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.openclaw.sh
```

**Ubuntu Desktop**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.openclaw.sh
```

**After reboot, configure OpenClaw**

Open a terminal and run:

```bash
openclaw onboard --install-daemon
```

**Careful: you are about to give AI some privileged access to your accounts!**

![](images/001.openclaw.config.png)

See the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started) guide for more details.

Back to [[Amazon Linux Guest - Workloads](../guest.amazon.linux/README.md)] or [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)]
