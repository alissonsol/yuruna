# Yuruna Template Project

Folder scaffold for a new project. See [../../CODE.md](../../CODE.md) for
the three-phase model and CLI entry points, and [FAQ](../../docs/faq.md)
Connectivity section before deploying.

## Deploy

Search for `TO-SET` in `config/<cloud>/*.yml` and fill required values,
then from the `automation/` folder:

```shell
Set-Resource.ps1  TO-SET localhost
Set-Component.ps1 TO-SET localhost
Set-Workload.ps1  TO-SET localhost
```

## Fill in

- **Resources** — project resources description and OpenTofu outputs.
- **Components** — project components description.
- **Workloads** — project workloads description.
- **Validation** — how to validate the system functionality.

Back to [[Yuruna](../../README.md)].
