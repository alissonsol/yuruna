# PostgreSQL

Installs [PostgreSQL](https://www.postgresql.org/).

| Guest | Command |
|---|---|
| **Amazon Linux 2023** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.postgresql.sh` |
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.postgresql.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.postgresql.sh` |

Verify:

```
sudo -u postgres psql -c "SELECT version();"
```

Download guides: [Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) ·
[Red Hat](https://www.postgresql.org/download/linux/redhat/).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.30

Back to [Yuruna](../README.md)
