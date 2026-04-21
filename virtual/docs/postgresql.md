# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest | Script |
|---|---|
| **Amazon Linux** | `amazon.linux.postgresql.sh` |
| **Ubuntu Desktop** | `ubuntu.desktop.postgresql.sh` |

**Amazon Linux**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.postgresql.sh
```

**Ubuntu Desktop**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.postgresql.sh
```

**Verify the installation**

```bash
sudo -u postgres psql -c "SELECT version();"
```

See the official PostgreSQL documentation for [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) and [Red Hat](https://www.postgresql.org/download/linux/redhat/) for more details.

Back to [[Amazon Linux Guest - Workloads](../guest.amazon.linux/README.md)] or [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)]
