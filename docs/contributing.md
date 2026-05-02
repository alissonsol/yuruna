# Yuruna Contributing Guidance

See [../CODE.md](../CODE.md) for project architecture and
[../test/CODE.md](../test/CODE.md) for the test-harness internals.

## Workflow

1. **Local configuration** — copy `test/test-config.json.template` to
   `test/test-config.json` (git-ignored), fill `notification.toAddress`
   and `secrets.resend` (see [../test/README.md](../test/README.md)).
   The runner strips everything under `secrets` from logged config.

2. **Branch + code changes** — if you modify files that guest VMs fetch
   via the "fetch and execute" pattern, push the branch before testing
   so the VM can download them (see
   [Testing changes from a branch](#testing-changes-from-a-branch)).

3. **Full test loop** — `pwsh test/Invoke-TestRunner.ps1`. Prints a
   `Log directory:` line at startup with the location of debug
   artifacts.

4. **Debug a specific step** — `Invoke-TestSequence.ps1` re-runs a
   single sequence from (or stopping at) a chosen step without VM
   re-creation:

   ```powershell
   pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.ubuntu.desktop" -StartStep 5
   pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.ubuntu.desktop" -StartStep 3 -StopStep 7
   ```

   The script lists all steps with markers showing which will execute
   and leaves the VM running when `-StopStep` is set.

## Overview

The link between YAML config and actions per command is explained in a
presentation: [PowerPoint](yuruna.pptx) · [PDF](yuruna.pdf).

## Guidelines

- **PowerShell** — run [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer):
  `Invoke-ScriptAnalyzer -Path . -Recurse`.
- **Resources** — keep OpenTofu files simple; minimize variables.
- **Components** — reusable components are best explained in an
  end-to-end example.
- **Workloads** — examples should demonstrate resource + component
  wiring and work on at least `localhost` and one cloud provider.

## Testing changes from a branch

Cloud-init and guest READMEs fetch scripts from `main`:

```
https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/ubuntu.desktop/ubuntu.desktop.code.sh
```

Branch changes aren't visible there until merged.

**Workload scripts** (self-contained): option A — clone on the guest,
`git checkout your-branch`, run the script directly. Option B — push
the branch and use `EXEC_BASE_URL` with `fetch-and-execute.sh`:

```bash
EXEC_BASE_URL="https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/your-branch-name/" \
  /automation/fetch-and-execute.sh guest/ubuntu.desktop/ubuntu.desktop.code.sh
```

**Cloud-init user-data**: URLs are baked into the seed ISO at
`New-VM.ps1` time. Before running `New-VM.ps1`, edit
`host/<short-host>/guest.*/vmconfig/user-data` and replace
`refs/heads/main` with your branch. **Revert before opening a PR.**

Back to [[Yuruna](../README.md)]
