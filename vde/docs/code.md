# Code

Installs Java (JDK), .NET SDK, Git, [Visual Studio Code](https://code.visualstudio.com/), and PowerShell.

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.code.sh` |
| **Ubuntu Desktop** | `ubuntu.desktop.code.sh` |

**Amazon Linux**

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.code.sh?nocache=$(date +%s)")"
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh?nocache=$(date +%s)")"
```

## Reminders

After installation, complete these steps before starting to code.

**Login to GitHub**

```bash
gh auth login
```

**Set git username and email**

```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

**Install extensions and login (e.g., Claude Code)**

```bash
code --install-extension anthropic.claude-code
```

Then open VS Code and sign in to each extension that requires authentication.

Back to [Amazon Linux guest](../guest.amazon.linux/README.md) or [Ubuntu Desktop guest](../guest.ubuntu.desktop/README.md)
