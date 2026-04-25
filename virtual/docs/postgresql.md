# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest | Command |
|---|---|
| **Amazon Linux** | `/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.postgresql.sh` |
| **Ubuntu Desktop** | `/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.postgresql.sh` |
| **Ubuntu Server** | `/automation/fetch-and-execute.sh virtual/guest.ubuntu.server/ubuntu.server.postgresql.sh` |

Verify:

```bash
sudo -u postgres psql -c "SELECT version();"
```

Upstream: [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) ·
[Red Hat](https://www.postgresql.org/download/linux/redhat/).

Back to [[Amazon Linux](../guest.amazon.linux/README.md)] ·
[[Ubuntu Desktop](../guest.ubuntu.desktop/README.md)] ·
[[Ubuntu Server](../guest.ubuntu.server/README.md)]
