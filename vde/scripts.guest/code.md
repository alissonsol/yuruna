# Code

Installs Java (JDK), .NET SDK, Git, and [Visual Studio Code](https://code.visualstudio.com/).

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.code.bash` |
| **Ubuntu Desktop** | `ubuntu.desktop.code.bash` |

**Amazon Linux**

```bash
wget --no-cache -O amazon.linux.code.bash https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/amazon.linux/amazon.linux.code.bash
chmod a+x amazon.linux.code.bash
bash ./amazon.linux.code.bash
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
wget --no-cache -O ubuntu.desktop.code.bash https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/ubuntu.desktop/ubuntu.desktop.code.bash
chmod a+x ubuntu.desktop.code.bash
bash ./ubuntu.desktop.code.bash
```

Back to [Post-VDE Setup](README.md)
