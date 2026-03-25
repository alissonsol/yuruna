# Yuruna Syntax

The connection between the YAML configuration files and the actions taken by each command is explained in a presentation available in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

## Syntax

Include the `automation` folder in the path. Then deploy resources, build components, and install workloads. The command syntax is shown below.

```shell
Set-Resource.ps1  [project_root] [config_subfolder] [options]
Set-Component.ps1 [project_root] [config_subfolder] [options]
Set-Workload.ps1  [project_root] [config_subfolder] [options]
```

## Commands

Each phase has its own PowerShell script:

- `Set-Resource.ps1 [project_root] [config_subfolder]`: Deploys resources using OpenTofu as helper (`tofu apply` is executed in the configured work folder).
- `Set-Component.ps1 [project_root] [config_subfolder]`: Builds and pushes components to registry.
- `Set-Workload.ps1 [project_root] [config_subfolder]`: Deploys workloads using Helm as helper (`helm install` is executed in the configured work folder).

You can execute commands in "debug mode" setting the `debug_mode` parameter to true. For example:

- `Test-Configuration.ps1 [project_root] [config_subfolder] -debug_mode $true`

You can also execute commands in "verbose mode" setting the `verbose_mode` parameter to true. It should come after the `debug_mode` parameter. For example:

- `Test-Configuration.ps1 [project_root] [config_subfolder] -debug_mode $true -verbose_mode $true`

Additional commands are:

- `Invoke-Clear.ps1 [project_root] [config_subfolder]`: Clear resources for given configuration (`tofu destroy` is executed in the configured work folder).
- `Test-Configuration.ps1 [project_root] [config_subfolder]`: Validate configuration files.
- `Test-Requirements.ps1`: Check if machine has all requirements. [Under development]

## Notes

- A folder `.yuruna` is created under the `project_root` for the temporary files.

Back to [[Yuruna](../README.md)]
