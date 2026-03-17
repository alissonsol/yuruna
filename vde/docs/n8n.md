# n8n

Installs [n8n](https://n8n.io/) workflow automation.

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.n8n.bash` |
| **Ubuntu Desktop** | `ubuntu.desktop.n8n.bash` |

**Amazon Linux**

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.n8n.bash)"
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.n8n.bash)"
```

**Verify the installation**

```bash
n8n --version
```

**Start n8n**

```bash
n8n start
```

Then open `http://localhost:5678` in your browser.

See the official [n8n documentation](https://docs.n8n.io/) for more details.

Back to [Amazon Linux guest](../guest.amazon.linux/README.md) or [Ubuntu Desktop guest](../guest.ubuntu.desktop/README.md)
