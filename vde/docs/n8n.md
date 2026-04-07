# n8n

Installs [n8n](https://n8n.io/) workflow automation.

| Guest | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.n8n.sh` |
| **Ubuntu Desktop** | `ubuntu.desktop.n8n.sh` |

**Amazon Linux**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.n8n.sh
```

**Ubuntu Desktop**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.n8n.sh
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

Back to [[Amazon Linux Guest - Workloads](../guest.amazon.linux/README.md)] or [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)]
