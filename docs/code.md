# Code

Installs Java (JDK), .NET SDK, Git, [Visual Studio Code](https://code.visualstudio.com/),
and PowerShell. See [Yuruna Architecture](architecture.md) for the guest workload
pattern.

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.code.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.code.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.code.sh` |
| **Windows 11** | `irm "…/guest/windows.11/windows.11.code.ps1$nc" \| iex` (see [Windows 11 ...](../guest/windows.11/README.md)) |

## After install

```
gh auth login
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

Then open VS Code and sign in to each extension that needs it.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
