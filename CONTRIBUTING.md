# Yuruna Contributor Guidance

See [Yuruna Architecture](docs/architecture.md) for project architecture and
[Test harness](docs/test-harness.md) for the test-harness internals.

Looking for something to work on? Pick from
[Contributor opportunities](docs/opportunities.md).

The [public](https://yuruna.com) repository should be used for test labs and learning. Contact the contributor
[email](mailto:contrib@yuruna.dev) for access to the [development](https://yuruna.dev)
repository.

## Workflow

1. **Get the "dev" repositories mapped locally**

  - Assuming "`git`" is your base folder.
     ```
       git% git clone https://github.com/alissonsol/yurunadev yuruna
       git% git clone https://github.com/alissonsol/yurunadev-project yuruna-project
     ```

   - Confirm you are working on the "dev" repositories:
     ```
       git/yuruna% git config --get remote.origin.url
               https://github.com/alissonsol/yurunadev
       git/yuruna-project% git config --get remote.origin.url
                       https://github.com/alissonsol/yurunadev-project
     ```

2. **Configure for local development**

  - Copy `test/test.config.yml.template` to
   `test/test.config.yml` (gitignored).
  - For the local project changes to be used in tests, change the projectUrl in the `test.config.yml` file.

    - Example for Windows
      ```
       repositories:
         frameworkUrl: https://github.com/alissonsol/yurunadev
         projectUrl: file:///c:/git/yuruna-project
      ```

    - Example for macOS
      ```
       repositories:
         frameworkUrl: https://github.com/alissonsol/yurunadev
         projectUrl: file:////Users/[username]/git/yuruna-project
      ```

  - If you modify files that guest VMs fetch
   via the "fetch and execute" pattern, commit your changes before testing
   so the VM can download them via the status server "interceptor" (see
   [Testing changes from a branch](#testing-changes-from-a-branch)).
  - When you look at the diagnostics for any running test sequence, check the `Yuruna version` and `Project version` fields at the beginning of the `YURUNA PROJECT` section.

3. **Extensions configuration**

  - Notification credentials and
   subscriber lists live in
   `test/status/extension/notification/transports.yml` (also gitignored).
    - Copy
   `test/extension/notification/transports.yml.template` to the runtime
   location above and fill in
   `transports.resend.apiKey`, `transports.resend.fromEmail`, plus the
   `subscribers["cycle.failure"]` list.
    - See
   [Test Runner — Nerd-Level Details](test/read.more.md) for the full notification
   setup. Test-user credentials are managed by the
   `test/extension/authentication/` extension (live vault.yml lives at
   `test/status/extension/authentication/vault.yml`, gitignored;
   persists across cycles to simulate an external auth provider).

4. **Project work**

  - As long as your local `frameworkUrl` configuration points to the "`yurunadev`" branch, it is business as usual with git, with the bonus of all committed changes being served to your guests via the "status server interceptor".
  - Working on a project, including the framework sample project, requires a deeper understanding of "git details". If the projectUrl points to an external site (like `GitHub.com`), then the "status server interceptor" doesn't serve its local commits. Why? Because you can clone that remote repository into multiple local folders. Which one would contain the code you want "intercepted"?
    - Solutions are:
      - Serve the folder you want as a git repository using the git daemon.
        ```
        git daemon --verbose --export-all --base-path=. --enable=receive-pack
        ```
        Then, change the projectUrl to point to your server
        ```
        projectUrl: git://server-name-or-ip/project-folder
        ```
        This is a solution for a small group working within a local network. Remember to commit changes!
      - For testing changes on a single machine, point directly to the local folder.
        ```
        projectUrl: file:///c:/git/yuruna-project
        ```
        Remember to ... commit changes!

5. **Testing your project**

  Test steps assume a PowerShell terminal (with Administrator permissions in Windows)

  - Start the Yuruna caching project
    - Locally: `test/Start-CachingProxy.ps1`
    - For a remote cache: `$env:YURUNA_CACHING_PROXY_IP = 'x.y.z.p'`
    - Test: `test/Test-CachingProxy.ps1` 
  - Single test loop: `test/Test-Project.ps1`
  - Test runner: `test/Invoke-TestRunner.ps1`.

6. **Debug a specific step**
  - `Test-Sequence.ps1` re-runs a
   single sequence from (or stopping at) a chosen step without VM
   re-creation:

     ```
     test/Test-Sequence.ps1 -SequenceName "start.guest.ubuntu.server.24" -StartStep 5
     test/Test-Sequence.ps1 -SequenceName "start.guest.ubuntu.server.24" -StartStep 3 -StopStep 7
     ```

   The script lists all steps with markers showing which will execute
   and leaves the VM running when `-StopStep` is set.

## Overview

The link between YAML config and actions per command is explained in
[Yuruna Syntax](docs/syntax.md) and [Yuruna Architecture](docs/architecture.md). Operator tips and
workarounds collected during development live in [Yuruna Workarounds](docs/workarounds.md).

## Guidelines

- **PowerShell** — run [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer):
  `Invoke-ScriptAnalyzer -Path . -Recurse`. The repo ships a
  `PSScriptAnalyzerSettings.psd1` that PSSA auto-discovers; all
  Error- and Warning-severity findings (including
  `PSUseBOMForUnicodeEncodedFile`) must be zero before merge.
- **Resources** — keep OpenTofu files simple; minimize variables.
- **Components** — reusable components are best explained in an
  end-to-end example.
- **Workloads** — examples should demonstrate resource + component
  wiring and work on at least `localhost` and one cloud provider.

## Testing changes from a branch

**Interceptor**

  The concept of the interceptor is simple. You can test locally submitted changes without pushing to the repository. The status server "intercepts" your requests if you used the "fetch and execute" pattern, and serves the local commits affecting the framework. Even for the development repository, you don't want to push untested changes. More details on the definition of the "[Fetch-and-execution contract](http://yuruna.link/definition#fetch-and-execution-contract)".

**Testing workload scripts** (self-contained):

  - Option A — clone on the guest,
`git checkout your-branch`, run the script directly.
  - Option B — push
the branch and use `EXEC_BASE_URL` with `fetch-and-execute.sh`:
    ```
    EXEC_BASE_URL="https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/your-branch-name/" \
    /automation/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.code.sh
    ```

**Cloud-init user-data**: URLs are baked into the seed ISO at
`New-VM.ps1` time. Before running `New-VM.ps1`, edit
`host/<short-host>/guest.*/vmconfig/user-data` and replace
`refs/heads/main` with your branch. **Revert before opening a PR.**

Back to [Yuruna](README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
