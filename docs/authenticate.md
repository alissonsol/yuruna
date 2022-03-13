# `yuruna` authentication instructions

## Docker Desktop

- No need to authenticate!

## AWS

- It is recommended that you create an administrator user for this application instead of using the root user, as per [guidance](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html).
- Login to AWS using [CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) (should be needed just once from PowerShell session).
  - `aws configure`
    - Enter `AWS Access Key ID`, `AWS Secret Access Key`, `Default region name`, and `Default output format`
  - Show current [configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)
    - `aws configure list`
      - Check if your account has completed creation with the command: `aws eks list-clusters`

## Azure

- Login to Azure and select subscription (should be needed just once from PowerShell session).
  - `az login --use-device-code`
  - If needed: show available subscriptions and set default
    - `az account list -o table`
    - `az account set --subscription xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx`
    - Show current subscription
      - `az account show --query "{name:name, isDefault:isDefault, id:id, user:user.name}" -o tsv`

## Google Cloud

- Initialization (to be done once)
  - Check currently active configuration: `gcloud config list`
  - Initialize the configuration and project
    - It is recommended to start a new configuration and project with `gcloud init --skip-diagnostics`
      - Create new configuration and project, so that you don't disrupt any other work
  - Enable required APIs (Change project name as needed)
    - Navigate to <https://console.developers.google.com/apis/library/compute.googleapis.com?project=yuruna>. Click `Enable API`. If this is the first API enabled for the project, it will require enabling billing.
    - Navigate to <https://console.developers.google.com/apis/library/compute.googleapis.com?project=yuruna>. Click `Enable API`.
    - Navigate to <https://console.developers.google.com/apis/library/containerregistry.googleapis.com?project=yuruna>. Click `Enable API`.
  - Make sure that a default region is set for the project
    - Execute: `gcloud compute project-info describe --project [project]`
    - If needed, changed the default region with: `gcloud compute project-info add-metadata --metadata google-compute-default-region=[region]`
      - It is recommmended that the default region is set to the same used in the `terraforms.tfvars` file.
  - GCP Docker Registry Access
    - Create a service account with the role 'Container Registry Service Agent'. You can also use the one automatically added when you enabled the Container Registry API [link](https://cloud.google.com/container-registry/docs/overview#container_registry_service_account).
    - Creating the JSON access key file
      - Navigate to the [API credentials](https://console.cloud.google.com/apis/credentials?project=yuruna) page for your project.
      - Select the service account (click on link) to take you to the "Service Account Details".
      - Under "Keys", select "Add Key". Then, "Create new key" and select the "JSON" format. When pressing "CREATE", you will have a file downloaded.
        - Save the file overwriting `config/gcp-access-key.json`

- Authentication (to be done per session)
  - Verify the default values with: `gcloud config list`
  - Set the active configuration
    - Verify which configuration is active: `gcloud config configurations list`
    - If needed, activate the desired configuration: `gcloud config configurations activate [configuration]`
  - Set the active project
    - List projects with: `gcloud projects list`
    - Configure default project with: `gcloud config set project [project]`
  - Authorize the SDK to access GCP: `gcloud auth application-default login`

Back to main [readme](../README.md)
