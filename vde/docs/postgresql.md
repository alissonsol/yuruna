# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest Environment | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.postgresql.bash` |
| **Ubuntu Desktop** | `ubuntu.desktop.postgresql.bash` |

**Amazon Linux**

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/amazon.linux/amazon.linux.postgresql.bash)"
```

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/ubuntu.desktop/ubuntu.desktop.postgresql.bash)"
```

**Verify the installation**

```bash
sudo -u postgres psql -c "SELECT version();"
```

See the official PostgreSQL documentation for [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) and [Red Hat](https://www.postgresql.org/download/linux/redhat/) for more details.

Back to [Post-VDE Setup](README.md)
