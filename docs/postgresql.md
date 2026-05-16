# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest | Command |
|---|---|
| **Amazon Linux** | `/automation/fetch-and-execute.sh guest/amazon.linux/amazon.linux.postgresql.sh` |
| **Ubuntu Server** | `/automation/fetch-and-execute.sh guest/ubuntu.server/ubuntu.server.postgresql.sh` |

Verify:

```bash
sudo -u postgres psql -c "SELECT version();"
```

Upstream: [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) ·
[Red Hat](https://www.postgresql.org/download/linux/redhat/).

Back to [Amazon Linux ...](../guest/amazon.linux/README.md) ·
[Ubuntu Server ...](../guest/ubuntu.server/README.md) ·
[Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
