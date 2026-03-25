# Yuruna Contributing Guidance

## Overview

- The connection between the YAML configuration files and the actions taken by each command is explained in a presentation available in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

## PowerShell

- Ensure modifications and additions to PowerShell code don't add new issues as pointed out by the [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
  - `Invoke-ScriptAnalyzer -Path .`

## Resources

- Create a simple configurable set of OpenTofu files with minimal amount of variables.
  - Create example using the template set for clarity.

## Components

- Simple reusable components are better explained in the context of an end-to-end example.

## Workloads

- Examples should focus on demonstrating use of resources and connection of components when deploying workloads.
  - Should work at least for `localhost` and one cloud provider.

## Testing script changes from a branch

The documentation and cloud-init files fetch scripts from the `main` branch via URLs like:

```
https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

When working on a branch, your changes are not available at those URLs until merged. There are two approaches to test your changes, depending on what you are modifying.

### Workload scripts

The workload scripts (e.g., `ubuntu.desktop.code.sh`, `windows.11.code.ps1`) are self-contained. To test changes on a guest VM:

**Option A: Run from a local clone (recommended)**

Clone the repository on the guest VM, checkout your branch, and run the script directly.

```bash
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
git checkout your-branch-name
bash vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

For Windows 11 guests:

```powershell
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
git checkout your-branch-name
.\vde\guest.windows.11\windows.11.code.ps1
```

**Option B: Fetch from your branch**

Push your branch and replace `main` with your branch name in the one-liner URL. For example:

```bash
/bin/bash -c "$(wget -qO- "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/your-branch-name/vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh?nocache=$(date +%s)")"
```

### Cloud-init user-data files

The `vmconfig/user-data` files under each host/guest combination download scripts during VM creation (e.g., `amazon.linux.update.sh`). These URLs are baked into the seed ISO when `New-VM.ps1` runs, so the VM will always fetch from whatever branch the user-data file points to.

To test changes to scripts that cloud-init downloads:

1. Edit the `user-data` file in your local clone before creating the VM.
2. Replace `refs/heads/main` with `refs/heads/your-branch-name` in the download URLs.
3. Run `New-VM.ps1` as usual — the new VM will fetch scripts from your branch.

The `user-data` files that contain these URLs are:

- `vde/host.macos.utm/guest.amazon.linux/vmconfig/user-data`
- `vde/host.macos.utm/guest.ubuntu.desktop/vmconfig/user-data`
- `vde/host.windows.hyper-v/guest.amazon.linux/vmconfig/user-data`
- `vde/host.windows.hyper-v/guest.ubuntu.desktop/vmconfig/user-data`

**Important:** Remember to revert the `user-data` changes before submitting a pull request, so the merged code continues to point to `main`.

Back to [[Yuruna](../README.md)]
