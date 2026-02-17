# `yuruna` template project

Folder structure template project.

## End-to-end deployment

Below are the end-to-end steps to deploy the `template` project to `localhost` (assuming Docker is installed and Kubernetes enabled). The execution below is from the `automation` folder. You may need to start PowerShell (`pwsh`).

Before deploying, seek for `TO-SET` in the config files and set the required values. See section "Cloud deployment instructions".

**IMPORTANT**: Before proceeding, read the Connectivity section of the [Frequently Asked Questions](../../docs/faq.md).

- Create resources

```shell
Set-Resource.ps1 TO-SET localhost
```

- Build the components

```shell
Set-Component.ps1 TO-SET localhost
```

- Deploy the workloads

```shell
Set-Workload.ps1 TO-SET localhost
```

## Resources

Terraform will be used to create the following resources:

- Project resources description.

As output, the following values will become available for later steps:

- Project resources output description.

## Components

- Project components description.

## Workloads

- Project workloads description.

## Validation

- How to validate the system functionality.

Back to the main [readme](../../README.md).