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
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.code.ps1?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" | iex
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

Back to [[Amazon Linux Guest - Workloads](../guest.amazon.linux/README.md)], [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)], or [[Windows 11 Guest - Workloads](../guest.windows.11/README.md)]
