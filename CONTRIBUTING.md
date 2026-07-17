# Yuruna Contributor Guidance

See [Yuruna Architecture](docs/architecture.md) for project architecture and
[Test harness](docs/test-harness.md) for the test-harness internals.

Looking for something to work on? Pick from
[Contributor opportunities](docs/opportunities.md).

The [public](https://yuruna.com) repository should be used for test labs and learning. For access to the [development](https://yuruna.dev)
repository, contact [contrib@yuruna.dev](mailto:contrib@yuruna.dev).

## Private repository bootstrap

Once your account has access to the private `yurunadev` repository,
use the instructions below, instead of the one-liner installers in
the [install/README.md](install/README.md).

### a. Install the GitHub CLI

| Platform | One-liner |
|---|---|
| macOS (Homebrew present) | `brew install gh` |
| Ubuntu / Debian (snap path) | `sudo snap install gh` |
| Amazon Linux 2023 / Fedora / RHEL | `sudo dnf install gh` |
| Windows | `winget install --id GitHub.cli --source winget --silent` |

The non-snap apt-repo route on Ubuntu is documented at
[cli.github.com](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

To execute PowerShell scripts in Windows, verify [execution policy](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies) settings.

### b. Authenticate

  ```
  gh auth login
  ```

Pick `GitHub.com` → `HTTPS` → browser (recommended) or a Personal Access
Token with at minimum the `repo` scope. The token `gh` stores is the same
one accepted by `raw.githubusercontent.com` for private repo reads.

#### Personal Access Token (PAT)

Likely the best path for those using the command line and environments like Linux.

- Go to GitHub -> Settings -> Developer Settings -> Personal Access Tokens -> Tokens (classic).
- Generate a token with repo, workflow, and read:org scope
- Linux environment
  - Edit the file `~/.bashrc` to add the following line:
    ```
    export GH_TOKEN="ghp_YourGeneratedTokenGoesHere"
    ``` 
  - This command appends it to the file from the Bash shell.
    ```
    echo 'export GH_TOKEN="ghp_YourGeneratedTokenGoesHere"' >> ~/.bashrc && source ~/.bashrc
    ```

### c. Get the "dev" repositories mapped locally

  - Assuming "`git`" is your base folder.
     ```
       git% git clone https://github.com/alissonsol/yurunadev yuruna
       git% git clone https://github.com/alissonsol/yurunadev-project yuruna-project
     ```

  - If using the command line tool and the Personal Access Token, use `gh repo` commands.
     ```
       git% gh repo clone https://github.com/alissonsol/yurunadev yuruna
       git% gh repo clone https://github.com/alissonsol/yurunadev-project yuruna-project
     ```

  - Configure local Git variables to ease committing and pushing changes later
    ```
    git config --global user.name "Your Name"
    git config --global user.email "Your@email.address"
    git config --global core.autocrlf input
    ```

  - Go to the `install` folder and run the script for your host type:
    - For macOS, run under a Bash shell: `macos.utm.sh`
    - For Ubuntu, run under a Bash shell: `ubuntu.kvm.sh`
    - For Windows, run under a PowerShell: `windows.hyper-v.ps1`

  - Other scripts for convenience.
    - `test/Enable-TestAutomation.ps1`: Change host settings to avoid screen savers and other disruptions for long test cycles.
    - `test/Sync-HostConfiguration.ps1`: Copy host configuration (`test.config.yml`) parameters from another host.
    - `test/Test-CachingProxy.ps1`: Test the connectivity to the caching proxy.
    - `test/Test-Config.ps1`: Test if the host configuration has valid values.

## Workflow

### 1. **Confirm you are working on the "dev" repositories**

  - Use the command below under your local repository folder.
     ```
       git config --get remote.origin.url
     ```

   - Double-check your results point to the "dev" repositories:
     ```
       git/yuruna% git config --get remote.origin.url
               https://github.com/alissonsol/yurunadev
       git/yuruna-project% git config --get remote.origin.url
                       https://github.com/alissonsol/yurunadev-project
     ```

**Please do not proceed until you are working on the "dev" repositories.**

No assistance will be provided to help migrate changes you made in the public repositories to "dev" repositories.

### 2. **Configure for local development**

  - Copy `yuruna/test/test.config.yml.template` to
   `yuruna/test/test.config.yml` (gitignored).
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
         projectUrl: file:///Users/[username]/git/yuruna-project
      ```

#### `repositories.GH_TOKEN` — reading a private framework/project repo

Leave `GH_TOKEN: ""` if both `frameworkUrl` and `projectUrl` are public. You
need it only when a guest has to read a **private** repo — either to clone
the framework/project, or to fetch its update script from GitHub when the host
status server is unreachable.

**Use a read-only, fine-grained token scoped to exactly those two repositories.**
This token is copied onto every test VM and is served by the status server on
`/control/test-config`, so anything that can reach the host on port 8080 can read
it. Its blast radius should be "read these two repos", nothing more — the guests
only ever pull.

- GitHub → *Settings* → *Developer settings* → *Personal access tokens* →
  **Fine-grained tokens** → *Generate new token*.
- **Resource owner:** the account that owns both repos (e.g. `alissonsol`).
- **Repository access:** *Only select repositories* → select **both**
  `yurunadev` **and** `yurunadev-project`.
- **Permissions** → *Repository permissions* → **Contents: Read-only**. That is
  the only one needed: it covers `git clone` / `fetch` / `pull` over HTTPS *and*
  the Contents API the GitHub fallback reads. (*Metadata: Read-only* is added
  automatically and cannot be removed.) Grant nothing else — no write, no
  `workflow`, no org permissions.
- Set an **expiration** and rotate it. Re-issuing is a one-line config edit.

The result looks like `github_pat_…`:

```
 repositories:
   frameworkUrl: https://github.com/alissonsol/yurunadev
   GH_TOKEN: "github_pat_YourReadOnlyTokenGoesHere"
   projectUrl: https://github.com/alissonsol/yurunadev-project
```

Two constraints worth knowing before you generate one:

- **A fine-grained token covers a single resource owner.** It works here because
  `frameworkUrl` and `projectUrl` live under the same account. If they ever move
  to different owners or orgs, no single fine-grained token can pull from both,
  and `repositories.GH_TOKEN` holds only one — you would need the repos under a
  common owner, or a GitHub App.
- **A classic PAT is a poor fit.** Its smallest useful scope, `repo`, is
  read-**write** and reaches *every* repository the account can see. On a
  credential that lives on disk in every guest VM, that is a much larger blast
  radius than this job needs. Prefer fine-grained; use classic only if you must.

The token never travels over the VM console (the host screenshots and OCRs that
into the published run log) — guests receive it on the cloud-init seed. It is
also kept out of `~/.gitconfig`, out of remote URLs, and out of the process list.
`test/test.config.yml` is gitignored, so the real value is never committed; only
the empty `GH_TOKEN: ""` in the template is.

  - If you modify files that guest VMs fetch
   via the [fetch-and-execution contract](https://yuruna.link/definition#fetch-and-execution-contract),
   commit your changes before testing
   so the VM can download them via the status server "interceptor" (see
   [Testing changes from a branch](#testing-changes-from-a-branch)).
  - When you look at the diagnostics for any running test sequence, check the `Yuruna version` and `Project version` fields at the beginning of the `YURUNA PROJECT` section.

### 3. **Extensions configuration**

  - Notification credentials and
   subscriber lists are split between a checked-in template and a
   gitignored runtime file:
    - **Template (checked in):**
   `test/extension/notification/transports.yml.template`.
    - **Runtime (gitignored):**
   `test/status/extension/notification/transports.yml`.
    - Copy the template to the runtime location and fill in
   `transports.resend.apiKey`, `transports.resend.fromEmail`, plus the
   `subscribers["cycle.failure"]` list.
    - See
   [Test Runner — Nerd-Level Details](test/read.more.md) for the full notification
   setup. Test-user credentials are managed by the
   `test/extension/authentication/` extension (live vault.yml lives at
   `test/status/extension/authentication/vault.yml`, gitignored;
   persists across cycles to simulate an external auth provider).

### 4. **Project work**

  - As long as your local `frameworkUrl` configuration points to the "`yurunadev`" branch, it is business as usual with git, with the bonus of **all committed changes** being served to your guests via the "status server interceptor".

### 5. **Running Tests**

  - If not using a local caching proxy, set the address of that server —
    durably via `vmStart.cachingProxyIP` in `test/test.config.yml` (probed
    first at cycle start), or for the session only via the fallback env var
    (consulted only when the config key is empty or unreachable):
    ```
    $env:YURUNA_CACHING_PROXY_IP = 'x.y.z.a'
    ```
  
  - Test your configuration and address errors and understand the warnings.
    - Test just the caching proxy: `test/Test-CachingProxy.ps1`
    - Check the configuration: `test/Test-Config.ps1`

#### **Ensuring local changes are used in tests**

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
        Remember to commit changes!

### 6. **Testing your project**

  Test steps assume a PowerShell terminal (with Administrator permissions in Windows)

  - Start the Yuruna caching proxy
    - Locally: `test/Start-CachingProxy.ps1`
    - For a remote cache: set `vmStart.cachingProxyIP` in `test/test.config.yml` (probed first), or `$env:YURUNA_CACHING_PROXY_IP = 'x.y.z.p'` when the config key is empty
    - Test: `test/Test-CachingProxy.ps1`
  - Single test loop: `test/Test-Project.ps1`
  - For running unattended tests, see the [Test Runner](docs/test-runner.md) documentation.

### 7. **Debug a specific step**
  - `Test-Sequence.ps1` re-runs a
   single sequence from (or stopping at) a chosen step without VM
   re-creation:

     ```
     test/Test-Sequence.ps1 -SequenceName "start.guest.ubuntu.server.24" -StartStep 5
     test/Test-Sequence.ps1 -SequenceName "start.guest.ubuntu.server.24" -StartStep 3 -StopStep 7
     ```

   The script lists all steps with markers showing which will execute
   and leaves the VM running when `-StopStep` is set.

## Configuration

The link between YAML config and actions per command is explained in
[Yuruna Syntax](docs/syntax.md) and [Yuruna Architecture](docs/architecture.md). Operator tips and
workarounds collected during development live in [Yuruna Workarounds](docs/workarounds.md).

## Guidelines

- **PowerShell** — run [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer):
  `Invoke-ScriptAnalyzer -Path . -Recurse`. The repo ships a
  `PSScriptAnalyzerSettings.psd1` that PSSA auto-discovers; it does not
  filter by severity, so findings of every severity must be zero before
  merge — including Information-level results (missing comment help,
  undeclared output types, positional-parameter calls) and
  `PSUseBOMForUnicodeEncodedFile`.
- **Commit hook** — a repo-tracked `tools/githooks/pre-commit` runs the
  ASCII/no-BOM gate (`test/Test-AsciiNoBom.ps1`) and blocks a commit that
  would put a BOM or non-ASCII byte into a byte-parsed bootstrap script
  (`irm|iex` / `curl|bash`) or first-run guest script. The install scripts
  activate it automatically via `.gitconfig.yuruna`; on a clone set up by
  hand, enable it once with
  `git config --local core.hooksPath tools/githooks`. It is advisory —
  skipped when `pwsh` is absent and bypassable with
  `git commit --no-verify` — so the release script must run the same gate as
  a hard precondition (the authoritative check for the published artifact).
- **Resources** — keep OpenTofu files simple; minimize variables.
- **Components** — reusable components are best explained in an
  end-to-end example.
- **Workloads** — examples should demonstrate resource + component
  wiring and work on at least `localhost` and one cloud provider.

## Testing changes from a branch

**Interceptor**

  The concept of the interceptor is simple. You can test locally submitted changes without pushing to the repository. The status server "intercepts" your requests if you used the "fetch and execute" pattern, and serves the local commits affecting the framework. Even for the development repository, you don't want to push untested changes. More details on the definition of the "[Fetch-and-execution contract](https://yuruna.link/definition#fetch-and-execution-contract)".

**Testing workload scripts** (self-contained):

  - Option A — clone on the guest,
`git checkout your-branch`, run the script directly.
  - Option B — push
the branch and use `EXEC_BASE_URL` with `fetch-and-execute.sh`:
    ```
    EXEC_BASE_URL="https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/your-branch-name/" \
    /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.code.sh
    ```

**Cloud-init user-data**: URLs are baked into the seed ISO at
`New-VM.ps1` time. Before running `New-VM.ps1`, edit
`host/<short-host>/guest.*/vmconfig/user-data` and replace
`refs/heads/main` with your branch. **Revert before opening a PR.**

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](README.md)
