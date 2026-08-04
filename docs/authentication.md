# Yuruna Authentication Instructions

How an operator authenticates to each supported cloud, how the
component-push pipeline authenticates to a container registry
unattended, and the threat model for the test harness's credential store.

## Docker Desktop

- No need to authenticate!

## AWS

- Create an administrator user (not the root user) per [AWS guidance](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html).
- Login with the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) (once per PowerShell session):
  - `aws configure` — enter `AWS Access Key ID`, `AWS Secret Access Key`, `Default region name`, `Default output format`.
  - Show [current configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html): `aws configure list`.
  - Verify the account is ready: `aws eks list-clusters`.

## Azure

- Login and select a subscription (once per PowerShell session):
  - `az login --use-device-code`
  - If needed: list and set a default subscription:
    - `az account list -o table`
    - `az account set --subscription xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx`
    - Show current: `az account show --query "{name:name, isDefault:isDefault, id:id, user:user.name}" -o tsv`

## Google Cloud

> **Note:** GCP deployment is planned and not yet available — the
> `global/resources/gcp/` resource templates do not ship yet. These steps
> prepare for it.

- One-time initialization:
  - Check currently active configuration: `gcloud config list`
  - `gcloud init --skip-diagnostics` — start a new configuration and project so you don't disrupt other work.
  - Enable required APIs (adjust project name as needed). If this is the first API enabled for the project, billing must also be enabled.
    - <https://console.developers.google.com/apis/library/compute.googleapis.com?project=yuruna> → `Enable API`
    - <https://console.developers.google.com/apis/library/containerregistry.googleapis.com?project=yuruna> → `Enable API`
  - Set a default region for the project (preferably the same region used in the OpenTofu resource config):
    - Inspect: `gcloud compute project-info describe --project [project]`
    - Change: `gcloud compute project-info add-metadata --metadata google-compute-default-region=[region]`
  - GCP Docker Registry Access:
    - Create a service account with the role 'Container Registry Service Agent' (or reuse the one [auto-added](https://cloud.google.com/container-registry/docs/overview#container_registry_service_account) when you enabled the Container Registry API).
    - Create the JSON access key file:
      - Open the [API credentials](https://console.cloud.google.com/apis/credentials?project=yuruna) page and click the service account.
      - Under "Keys", select `Add Key` → `Create new key` → `JSON` → `CREATE`. Save the downloaded file as `global/config/gcp/gcp-access-key.json`.

- Per-session authentication:
  - Check defaults: `gcloud config list`
  - Active configuration: `gcloud config configurations list`; activate with `gcloud config configurations activate [configuration]`.
  - Active project: `gcloud projects list`; then `gcloud config set project [project]`.
  - Authorize the SDK: `gcloud auth application-default login`.

## Component registry login

The steps above are what an operator types once per session. The
component-push pipeline in
[`automation/Yuruna.Component.psm1`](../automation/Yuruna.Component.psm1)
does the equivalent unattended: log into the target container
registry before pushing the built image. Supported registries
(Azure ACR, AWS ECR, Google Artifact Registry, Docker Hub, generic
Docker login) each use a different CLI and credential model. The
dispatcher in
[`automation/Yuruna.Component.Registry.psm1`](../automation/Yuruna.Component.Registry.psm1)
asks the credential-provider registry in
[`automation/Yuruna.CredentialProvider.psm1`](../automation/Yuruna.CredentialProvider.psm1)
"what is the login command for `<host>`?" and pipes the answer
through the same `Invoke-ComponentCommand` wrapper that handles
build / tag / push, so the `registryLogin` phase shares
`docker.stderr.log` and `docker.rc` with the rest of the pipeline.

The dispatcher keeps registry knowledge out of `Yuruna.Component`,
which carries no per-registry branching like
`if ($registryLocation -like '*azurecr.io*')`. Adding a registry
kind (ECR, GAR, Docker Hub, Harbor, Nexus, …) is one
`Register-CredentialProvider` call; nothing in `Yuruna.Component`
changes.

### Layering

Both `Yuruna.Component` and the credential-provider registry live in
`automation/`: the registry (the `$global:YurunaCredentialProviders`
anchor, `Register-CredentialProvider`, `Get-CredentialProvider`, and the
five built-in provider registrations) is in
[`automation/Yuruna.CredentialProvider.psm1`](../automation/Yuruna.CredentialProvider.psm1),
so the runtime component-push pipeline never imports from `test/`:
there is no `automation/ -> test/` import edge. The test-only helpers
(`Get-CredentialProviderMatrix`, `Repair-Credential`,
`Clear-CredentialProvider`) stay in
[`test/modules/Test.CredentialProvider.psm1`](../test/modules/Test.CredentialProvider.psm1),
which imports the automation module `-Global` and re-exposes
`Register`/`Get` to test callers. The bridge file
[`automation/Yuruna.Component.Registry.psm1`](../automation/Yuruna.Component.Registry.psm1)
concentrates the dispatch in one place.

### Public surface

| Function | Module | Used by |
|---|---|---|
| `Register-CredentialProvider -Type -Pattern -Authenticator [-LoginCommand]` | `Yuruna.CredentialProvider` | Built-in registrations at module load; external modules can add more |
| `Get-CredentialProvider -Target` | `Yuruna.CredentialProvider` | Dispatcher; introspection |
| `Get-CredentialProviderMatrix` | `Test.CredentialProvider` | Startup capability matrix |
| `Repair-Credential -Target` | `Test.CredentialProvider` | Self-heal path: re-auth after a 401 mid-push |
| `Clear-CredentialProvider` | `Test.CredentialProvider` | Tests only |
| `Resolve-ComponentRegistryLogin -RegistryLocation` | `Yuruna.Component.Registry` | The push pipeline; returns the login command string or `$null` |

Each provider exposes two scriptblocks:

- **`Authenticator`** — self-heal path
  (`Repair-Credential` after a 401). Runs the auth in-process
  (calls `az acr login`, `gcloud auth print-access-token | docker
  login`, …). Returns `[bool]`.
- **`LoginCommand`** — batch pipeline
  (`Yuruna.Component` push). Returns the shell command string the
  push pipeline pipes through its own logging wrapper, or `$null`
  when the environment doesn't have the credentials.

### Built-in providers

| Type | Pattern | Login command shape |
|---|---|---|
| `azurecr` | `\.azurecr\.io(/\|$)` | `az acr login -n <registry>` |
| `ecr` | `\.dkr\.ecr\.[^.]+\.amazonaws\.com(/\|$)` | `aws ecr get-login-password --region <region> \| docker login --username AWS --password-stdin <host>` |
| `gar` | `-docker\.pkg\.dev(/\|$)` | `gcloud auth print-access-token \| docker login -u oauth2accesstoken --password-stdin https://<host>` |
| `dockerhub` | `^(index\.)?docker\.io(/\|$)` | `$env:YURUNA_DOCKER_HUB_PASSWORD \| docker login --username $env:YURUNA_DOCKER_HUB_USERNAME --password-stdin` |
| `docker-generic` | `.+` | `$env:YURUNA_REGISTRY_PASSWORD \| docker login --username $env:YURUNA_REGISTRY_USERNAME --password-stdin <host>` |

Order matters and is preserved: more specific patterns precede the
catch-all `docker-generic`. The path-suffix tolerance (`(/|$)`) lets
`foo.azurecr.io/myimage` match the same provider as the bare host.

### Credential env vars

Docker Hub and `docker-generic` read credentials from environment
variables; the others derive auth from the operator's CLI context
(`az login`, `aws configure`, `gcloud auth login`) set up above:

| Env var | Used by |
|---|---|
| `YURUNA_DOCKER_HUB_USERNAME` / `YURUNA_DOCKER_HUB_PASSWORD` | `dockerhub` provider |
| `YURUNA_REGISTRY_USERNAME` / `YURUNA_REGISTRY_PASSWORD` | `docker-generic` provider |

When either env-var pair is missing, that provider's `LoginCommand`
returns `$null`: the push pipeline skips the login phase and the
operator's pre-existing docker credential helper handles the push.
This is the "no login needed" default for any registry without
provider-supplied credentials.

### Adding a new registry kind

1. Pick a `Type` name (`harbor`, `nexus`, `quay`, …) and a regex
   `Pattern` matching the host shape.
2. Implement both scriptblocks (self-heal `Authenticator` and batch
   `LoginCommand`); return `[bool]` and `[string]` respectively.
3. Call `Register-CredentialProvider` at the bottom of
   [`Yuruna.CredentialProvider`](../automation/Yuruna.CredentialProvider.psm1)
   in registration order — more specific patterns first.
4. The push pipeline picks up the new provider on the next outer
   restart.

### Related registries

- [Host-condition registry](test-harness.md#host-condition-registry) — same `New-YurunaRegistry` primitive, different domain.
- [Host I/O registry](host-io.md) — the older, two-level registry that established the pattern.
- [Remediation dispatcher](failure-schema.md#remediation-dispatcher) — calls `Repair-Credential` when a push fails with 401.

## Test-harness vault — threat model

The test harness keeps a separate, lightweight credential store at
`test/status/extension/authentication/vault.yml`. **This file is
plaintext YAML by design.** It is NOT a production secrets vault.

What lands in it: per-cycle passwords for the throwaway guest OS
accounts the harness creates (`yauser1`, `yuuser24`, `yt2sqluser`, etc.)
on test VMs wiped and rebuilt every cycle. The accounts
exist only inside the test VM; the harness rotates the password on
first contact via `Set-Password`, stores both `password` and
`previousPassword` so a half-applied rotation can recover, and never
exports the value off the local machine.

What never lands in it: cloud-provider credentials (`aws configure` /
`az login` / `gcloud auth …` keep their own files, see sections
above), API keys, registry tokens, SSH host keys (those live under
`test/status/ssh/`), or any operator personal credential.

Trust boundary:

| Layer | Mechanism | Why plaintext is acceptable |
|-------|-----------|----------------------------|
| Filesystem | The file is git-ignored (`.gitignore` rule `test/status/*/`); never committed, never synced. | An attacker with filesystem read access already has equivalent or greater capability — they're already on the operator's machine. |
| Process | Read+write serialized by a SHA-1-of-path named mutex; atomic temp+rename. | Concurrent cycles cannot corrupt the file; not a confidentiality control. |
| Audit | Every read / write / rotate is appended to `events.log` as one JSON line. Passwords never appear in the log. | Tampering detection, not encryption. |

If you extend the harness to drive a production system, do NOT
add production credentials to this vault. Wire a separate
authentication extension (see [Extensions API](extensions-api.md))
backed by DPAPI / system keyring / a real secret manager. Today's
`default` extension is intentionally minimal.

Implementation:
[`test/extension/authentication/default.psm1`](../test/extension/authentication/default.psm1)
(its header comment carries a one-line pointer back to this section).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.04

Back to [Yuruna](../README.md)
