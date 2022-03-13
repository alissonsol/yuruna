# `yuruna` contributing guidance

## Overview

- The connection between the Yaml configuration files and the actions taken by each command is explained in a presentation available in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

## PowerShell

- Ensure modifications and additions to PowerShell code don't add new issues as pointed by the [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
  - `Invoke-ScriptAnalyzer -Path .`

## Resources

- Create a simple configurable set of Terraform files with minimal amount of variables.
  - Create example using the template set for clarity.

## Components

- Simple reusable components are better explained in the context of an end-to-end example.

## Workloads

- Examples should focus on demonstrating use of resources and connection of components when deploying workloads.
  - Should work at least for `localhost` and one cloud provider.

Back to main [readme](../README.md)
