# Code

Installs Java (JDK), .NET SDK, Git, [Visual Studio Code](https://code.visualstudio.com/), and PowerShell.

| Guest | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.code.sh` |
| **Ubuntu Desktop** | `ubuntu.desktop.code.sh` |
| **Windows 11** | `windows.11.code.ps1` |

**Amazon Linux**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh vde/guest.amazon.linux/amazon.linux.code.sh
```

**Ubuntu Desktop**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

**Windows 11**

Open an elevated PowerShell terminal and run the following command.

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.code.ps1$nc" | iex
```

> Set `$env:YurunaCacheContent` to a unique datetime string to bypass a caching
> proxy; leave it unset to allow caching. See
> [docs/caching.md](../../docs/caching.md).

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

Back to [[Amazon Linux Guest - Workloads](../guest.amazon.linux/README.md)], [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)], or [[Windows 11 Guest - Workloads](../guest.windows.11/README.md)]
