# OpenClaw

Installs Git, Node.js, and [OpenClaw](https://docs.openclaw.ai/start/getting-started).

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.openclaw.bash` |
| **Ubuntu Desktop** | `ubuntu.desktop.openclaw.bash` |

**Amazon Linux**

```bash
wget --no-cache -O amazon.linux.openclaw.bash https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/amazon.linux/amazon.linux.openclaw.bash
chmod a+x amazon.linux.openclaw.bash
bash ./amazon.linux.openclaw.bash
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
wget --no-cache -O ubuntu.desktop.openclaw.bash https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/ubuntu.desktop/ubuntu.desktop.openclaw.bash
chmod a+x ubuntu.desktop.openclaw.bash
bash ./ubuntu.desktop.openclaw.bash
```

**After reboot, configure OpenClaw**

Open a terminal and run:

```bash
openclaw onboard --install-daemon
```

**Careful: you are about to give AI some precious access to your accounts!**

![](images/001.openclaw.config.png)

See the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started) guide for more details.

Back to [Post-VDE Setup](README.md)
