# Yuruna Syntax

The connection between the YAML configuration files and the actions
taken by each command is summarized below; see [architecture.md](architecture.md)
for the three-phase architecture (Resources -> Components -> Workloads)
and [CONTRIBUTING.md](../CONTRIBUTING.md) for an overview.

## Syntax

Add the `automation` folder to the path, then deploy resources, build components, and install workloads:

```shell
Set-Resource.ps1  [project_root] [config_subfolder] [options]
Set-Component.ps1 [project_root] [config_subfolder] [options]
Set-Workload.ps1  [project_root] [config_subfolder] [options]
```

## Commands

Each phase has its own PowerShell script:

- `Set-Resource.ps1 [project_root] [config_subfolder]`: Deploys resources using OpenTofu (`tofu apply` in the configured work folder).
- `Set-Component.ps1 [project_root] [config_subfolder]`: Builds and pushes components to the registry.
- `Set-Workload.ps1 [project_root] [config_subfolder]`: Deploys workloads using Helm (`helm install` in the configured work folder).

Add `-logLevel <level>` to control which PowerShell streams reach the
console. Levels: `Error|Warning|Information|Verbose|Debug` (each shows
itself + all higher-priority streams; Error is highest). Default
`Error` — only error messages visible.

- `Test-Configuration.ps1 [project_root] [config_subfolder] -logLevel Information`

For test-runner sessions the flag is tri-state (cmdline >
`test.config.yml` > `Information`): omit it to read `test.config.yml.logLevel`,
or pass `-logLevel <level>` to override. `-logLevel Verbose` shows what
each OCR engine is reading on every `waitForText` poll (the
operator-relevant signal when a step is hanging); `-logLevel Debug`
adds low-level capture/polling chatter.

Additional commands:

- `Invoke-Clear.ps1 [project_root] [config_subfolder]`: Clear resources for a given configuration (`tofu destroy` in the configured work folder).
- `Test-Configuration.ps1 [project_root] [config_subfolder]`: Validate configuration files.
- `Test-Requirement.ps1 [-logLevel <level>]`: Check that all required tools (PowerShell, OpenTofu, Helm, etc.) are available on the machine.

## Notes

- A folder `.yuruna` is created under the `project_root` for the temporary files.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
