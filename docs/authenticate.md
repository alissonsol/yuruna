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
      - Under "Keys", select `Add Key` → `Create new key` → `JSON` → `CREATE`. Save the downloaded file as `config/gcp-access-key.json`.

- Per-session authentication:
  - Check defaults: `gcloud config list`
  - Active configuration: `gcloud config configurations list`; activate with `gcloud config configurations activate [configuration]`.
  - Active project: `gcloud projects list`; then `gcloud config set project [project]`.
  - Authorize the SDK: `gcloud auth application-default login`.

Back to [[Yuruna](../README.md)]
