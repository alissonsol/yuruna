# `yuruna`

A developer toolset for cross-cloud Kubernetes-based applications. Check the [Yuruna YouTube channel](https://www.youtube.com/channel/UCl36lZ2MwZ0f6_QAUOmGNDw) for videos about the tools and examples.

## Requirements and cloud-specific steps

- Confirm tools [requirements](docs/requirements.md).
  - If PowerShell is installed, check versions with `yuruna.ps1 requirements`.
- [Authenticate](docs/authenticate.md) with your cloud provider
  - Instructions assume execution from a PowerShell prompt connected to the cloud account.
  - Depending on your cloud provider, the authentication may timeout and need to be repeated.
- *Windows Warnings*
  - Examples using Linux-based containers may not work if scripts have the wrong line termination when building locally.
  - The recommendation is to set `git config --global core.autocrlf input` before `git clone`.

## Using `yuruna` to deploy Kubernetes-based applications

**IMPORTANT**: Before proceeding, read the Connectivity section of the [Frequently Asked Questions](docs/faq.md).

Include the `automation` folder in the path. Then deploy resources, build components, and install workloads from a PowerShell command prompt. The syntax is shown below.

```shell
yuruna.ps1 resources  [project_root] [config_subfolder] [options]
yuruna.ps1 components [project_root] [config_subfolder] [options]
yuruna.ps1 workloads  [project_root] [config_subfolder] [options]
```

For example, these commands deploy the [website](examples/website/README.md) example to Azure, showing debug and verbose messages.

```shell
./yuruna.ps1 resources  ../examples/website azure -debug_mode $true -verbose_mode $true
./yuruna.ps1 components ../examples/website azure -debug_mode $true -verbose_mode $true
./yuruna.ps1 workloads  ../examples/website azure -debug_mode $true -verbose_mode $true
```

See project [examples](examples/README.md) and check the [syntax](docs/syntax.md) documentation for more details.

## Notes

- Scripts and examples are provided "as is" without guarantees. See [license](LICENSE.md). Always check for the [latest version](https://bit.ly/asol-yrn).
- Creating cloud resources and not deleting them may result in a growing bill even if they aren't used.
  - You should [clean up](docs/cleanup.md) resources if those won't be in use.
- Questions? Check the [FAQ](docs/faq.md) document first.
- Want to contribute: check the list of [to do](docs/todo.md) tasks, and the guidelines for [contributing](docs/contributing.md).
  - Review the [hacks](docs/hacks.md), [updates](docs/updates.md), and additional [references](docs/references.md).
- Thanks to all users and [contributors](docs/contributors.md)

Copyright (c) 2020-2022 by Alisson Sol et al.
