# Code

Installs Java (JDK), .NET SDK, Git, [Visual Studio Code](https://code.visualstudio.com/),
and PowerShell. See [../CODE.md](../CODE.md) for the guest workload
pattern.

| Guest | Command |
|---|---|
| **Amazon Linux** | `/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.code.sh` |
| **Ubuntu Desktop** | `/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.code.sh` |
| **Ubuntu Server** | `/automation/fetch-and-execute.sh virtual/guest.ubuntu.server/ubuntu.server.code.sh` |
| **Windows 11** | `irm "…/virtual/guest.windows.11/windows.11.code.ps1$nc" \| iex` (see [../guest.windows.11/README.md](../guest.windows.11/README.md)) |

## After install

```bash
gh auth login
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
code --install-extension anthropic.claude-code
```

Then open VS Code and sign in to each extension that needs it.

Back to [[Amazon Linux](../guest.amazon.linux/README.md)] ·
[[Ubuntu Desktop](../guest.ubuntu.desktop/README.md)] ·
[[Ubuntu Server](../guest.ubuntu.server/README.md)] ·
[[Windows 11](../guest.windows.11/README.md)]
