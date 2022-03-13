# `yuruna` syntax

The connection between the Yaml configuration files and the actions taken by each command is explained in a presentation available in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

## Syntax

Include the `automation` folder in the path. Then deploy resources, build components, and install workloads. The command syntax is shown below.

```shell
yuruna.ps1 resources  [project_root] [config_subfolder] [options]
yuruna.ps1 components [project_root] [config_subfolder] [options]
yuruna.ps1 workloads  [project_root] [config_subfolder] [options]
```

## Commands

The main PowerShell script is named `yuruna` and accepts the following parameters:

- `yuruna.ps1 resources [project_root] [config_subfolder]`: Deploys resources using Terraform as helper (`terraform apply` is executed in the configured work folder).
- `yuruna.ps1 components [project_root] [config_subfolder]`: Build and push components to registry.
- `yuruna.ps1 workloads [project_root] [config_subfolder]`: Deploy workloads using Helm as helper (`helm install` is executed in the configured work folder).

You can execute commands in "debug mode" setting the `debug_mode` parameter to true. For example:

- `yuruna.ps1 validate [project_root] [config_subfolder] -debug_mode $true`

You can also execute commands in "verbose mode" setting the `verbose_mode` parameter to true. It should come after the `debug_mode` parameter. For example:

- `yuruna.ps1 validate [project_root] [config_subfolder] -debug_mode $true -verbose_mode $true`

Additional commands are:

- `yuruna.ps1 clear [project_root] [config_subfolder]`: Clear resources for given configuration (`terraform destroy` is executed in the configured work folder).
- `yuruna.ps1 validate [project_root] [config_subfolder]`: Validate configuration files.
- `yuruna.ps1 requirements`: Check if machine has all requirements. [Under development]

## Notes

- A folder `.yuruna` is create under the `project_root` for the temporary files.

Back to main [readme](../README.md)
