# `yuruna` template project

Folder structure template project.

## End-to-end deployment

Below are the end-to-end steps to deploy the `template` project to `localhost` (assuming Docker is installed and Kubernetes enabled). The execution below is from the `automation` folder. You may need to start PowerShell (`pwsh`).

Before deploying, seek for `TO-SET` in the config files and set the required values. See section "Cloud deployment instructions".

**IMPORTANT**: Before proceeding, read the Connectivity section of the [Frequently Asked Questions](../../docs/faq.md).

- Create resources

```shell
./yuruna.ps1 resources ../examples/TO-SET localhost
```

- Build the components

```shell
./yuruna.ps1 components ../examples/TO-SET localhost
```

- Deploy the  workloads

```shell
./yuruna.ps1 workloads ../examples/TO-SET localhost
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

Back to main [readme](../../README.md).