# Yuruna Authentication Instructions

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

## Test-harness vault — threat model

The test harness keeps a separate, lightweight credential store at
`test/status/extension/authentication/vault.yml`. **This file is
plaintext YAML by design.** It is NOT a production secrets vault.

What lands in it: per-cycle passwords for the throwaway guest OS
accounts the harness creates (`yauser1`, `yuuser24`, `yt2sqluser`, etc.)
on test VMs that are wiped and rebuilt every cycle. The accounts
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
| Filesystem | The file is git-ignored (`.gitignore` rule `test/status/*/`); never committed, never sync'd. | An attacker with filesystem read access already has equivalent or greater capability — they're already on the operator's machine. |
| Process | Read+write serialized by a SHA-1-of-path named mutex; atomic temp+rename. | Concurrent cycles cannot corrupt the file; not a confidentiality control. |
| Audit | Every read / write / rotate is appended to `events.log` as one JSON line. Passwords never appear in the log. | Tampering detection, not encryption. |

If you ever extend the harness to drive a production system, do NOT
add production credentials to this vault. Wire a separate
authentication extension (see [Extensions API](extensions-api.md))
backed by DPAPI / system keyring / a real secret manager. Today's
`default` extension is intentionally minimal.

Implementation:
[`test/extension/authentication/default.psm1`](../test/extension/authentication/default.psm1)
(search for "Threat model" near the top of the module for the same
text in code).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
