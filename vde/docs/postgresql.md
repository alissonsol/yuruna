# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.postgresql.bash` |
| **Ubuntu Desktop** | `ubuntu.desktop.postgresql.bash` |

**Amazon Linux**

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.amazon.linux/amazon.linux.postgresql.bash?nocache=$(date +%s)")"
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.postgresql.bash?nocache=$(date +%s)")"
```

**Verify the installation**

```bash
sudo -u postgres psql -c "SELECT version();"
```

See the official PostgreSQL documentation for [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) and [Red Hat](https://www.postgresql.org/download/linux/redhat/) for more details.

Back to [Amazon Linux guest](../guest.amazon.linux/README.md) or [Ubuntu Desktop guest](../guest.ubuntu.desktop/README.md)
