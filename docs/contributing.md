# Yuruna Contributing Guidance

## Guide: development and testing workflow

1. **Set up local configuration.** Copy `test/test-config.json.template` to `test/test-config.json` (gitignored). Open a [Resend](https://resend.com) account, create an API key, and fill in `notification.toAddress` and the `secrets.resend` block so failure alerts can be delivered. The runner strips everything under the top-level `secrets` node from logged config.

2. **Create a branch and make code changes.** If you modify files that guest VMs fetch via the "fetch and execute" pattern, push the branch before testing so the VM can download the updated scripts, and temporarily point the fetch base URL at your branch (see [Testing script changes from a branch](#testing-script-changes-from-a-branch) below).

3. **Run the full test loop.** `test/Invoke-TestRunner.ps1` runs the continuous test cycle. It prints a `Log directory:` line at startup showing where debug artifacts (OCR screenshots, etc.) are written.

   ```powershell
   pwsh test/Invoke-TestRunner.ps1
   ```

4. **Debug a specific sequence step.** On a failure, `test/Invoke-TestSequence.ps1` re-runs a single sequence starting from (or stopping at) a specific step, avoiding VM re-creation.

   ```powershell
   # Run from step 5 onward
   pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.ubuntu.desktop" -StartStep 5

   # Run only steps 3 through 7
   pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.ubuntu.desktop" -StartStep 3 -StopStep 7
   ```

   The script reuses an existing VM if one exists, lists all steps with markers showing which will execute, and leaves the VM running when `-StopStep` is specified so you can inspect its state.

## Overview

- The connection between the YAML configuration files and the actions taken by each command is explained in a presentation, in [PowerPoint](yuruna.pptx) and [PDF](yuruna.pdf) formats.

## PowerShell

- Keep modifications clean per [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer): `Invoke-ScriptAnalyzer -Path . -Recurse`

## Resources

- Keep OpenTofu files simple and configurable with a minimal number of variables. Use the template set to create clear examples.

## Components

- Simple reusable components are best explained in the context of an end-to-end example.

## Workloads

- Examples should demonstrate resources and component wiring when deploying workloads. They should work for at least `localhost` and one cloud provider.

## Testing script changes from a branch

Documentation and cloud-init files fetch scripts from the `main` branch via URLs like:

```
https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

Changes on a branch aren't visible at those URLs until merged. There are two approaches to test changes, depending on what you modify.

### Workload scripts

Workload scripts (e.g., `ubuntu.desktop.code.sh`, `windows.11.code.ps1`) are self-contained. To test changes on a guest VM:

**Option A: Run from a local clone (recommended)**

Clone the repository on the guest VM, checkout your branch, and run the script directly:

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
EXEC_BASE_URL="https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/your-branch-name/" /automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.code.sh
```

### Cloud-init user-data files

The `vmconfig/user-data` files under each host/guest combination download scripts during VM creation (e.g., `amazon.linux.update.sh`). Those URLs are baked into the seed ISO at `New-VM.ps1` time, so the VM always fetches from whatever branch the user-data file points to.

To test changes to scripts cloud-init downloads:

1. Edit the `user-data` file in your local clone before creating the VM.
2. Replace `refs/heads/main` with `refs/heads/your-branch-name` in the download URLs.
3. Run `New-VM.ps1` — the new VM will fetch scripts from your branch.

The `user-data` files that contain these URLs are:

- `vde/host.macos.utm/guest.amazon.linux/vmconfig/user-data`
- `vde/host.macos.utm/guest.ubuntu.desktop/vmconfig/user-data`
- `vde/host.windows.hyper-v/guest.amazon.linux/vmconfig/user-data`
- `vde/host.windows.hyper-v/guest.ubuntu.desktop/vmconfig/user-data`

**Important:** Remember to revert the `user-data` changes before submitting a pull request, so the merged code continues to point to `main`.

Back to [[Yuruna](../README.md)]
