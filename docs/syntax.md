# Yuruna Syntax

CLI command reference. The three-phase architecture and the project
layout live in [Yuruna Architecture](architecture.md); operator
workarounds are in [Yuruna Workarounds](workarounds.md).

## Commands

After `./Add-AutomationToPath.ps1`, run from a project folder:

```
Set-Resource.ps1  [project_root] [config_subfolder] [options]
Set-Component.ps1 [project_root] [config_subfolder] [options]
Set-Workload.ps1  [project_root] [config_subfolder] [options]
```

- `Set-Resource.ps1` — `tofu apply` in the configured work folder.
- `Set-Component.ps1` — build and push images to the registry.
- `Set-Workload.ps1` — `helm install` in the configured work folder.
- `Invoke-Clear.ps1` — `tofu destroy` in the configured work folder.
- `Test-Configuration.ps1` — validate configuration files.
- `Test-Requirement.ps1` — check required tools and versions.

## Log levels

`-logLevel <level>` controls which PowerShell streams reach the console.
Levels: `Error|Warning|Information|Verbose|Debug` (each shows itself +
all higher-priority streams; Error is highest). Defaults differ:
`Set-*`/`Test-Configuration`/`Invoke-Clear` default to `Error`; the
test runner (`Invoke-TestRunner.ps1`) defaults to `Information`.

For test-runner sessions the flag is tri-state (cmdline >
`test.config.yml.logLevel` > `Information`). `Verbose` shows what each
OCR engine reads on every `waitForText` poll (the operator-relevant
signal when a step is hanging); `Debug` adds low-level capture/polling
chatter.

## Notes

- A `.yuruna` folder is created under `project_root` for temporary files.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../README.md)
