# Yuruna Syntax

The connection between the YAML configuration files and the actions taken by each command is explained in a presentation, in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

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

Add `-debug_mode $true` for debug output, `-verbose_mode $true` for verbose output (verbose must come after debug):

- `Test-Configuration.ps1 [project_root] [config_subfolder] -debug_mode $true -verbose_mode $true`

Additional commands:

- `Invoke-Clear.ps1 [project_root] [config_subfolder]`: Clear resources for a given configuration (`tofu destroy` in the configured work folder).
- `Test-Configuration.ps1 [project_root] [config_subfolder]`: Validate configuration files.
- `Test-Requirements.ps1`: Check tool requirements. [Under development]

## Notes

- A folder `.yuruna` is created under the `project_root` for the temporary files.

Back to [[Yuruna](../README.md)]
