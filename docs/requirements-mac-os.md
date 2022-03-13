# `yuruna` macOS instructions

Shortcut through the many guides to install [requirements](./requirements.md) in the macOS.

Tested with macOS Monterrey: `sw_vers`: `ProductVersion: 12.2.1` : `BuildVersion: 21D62`. Test with both Intel processor and Apple M1.

## Upgrading the environment

If you previously performed the steps to install the requirements, get the latest versions with the command.

```shell
brew upgrade
```

## Steps that may need manual interaction

Steps that may need a password or other decisions before proceeding. First, install Brew (may need password and press to continue).

```shell
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

NOTE: When updating the installed versions, use `reinstall` instead of `install` in the commands below.

Install mkcert and then install the root certificates. May need to enter password twice when running `mkcert -install`.

```shell
brew install mkcert
mkcert -install
```

PowerShell may also need the password. Install also the module for Yaml.

```shell
brew install --cask powershell
pwsh
Install-Module -Name powershell-yaml
```

If not installed yet, install and configure Git.

```shell
brew install git
git config --global user.name "Your Name"
git config --global user.email "Your@email.address"
```

Install Docker.

```shell
brew install --cask docker
```

Start Docker from the `Applications` folder. Then, open the settings panel and [enable Kubernetes](https://docs.docker.com/docker-for-mac/#kubernetes).

## Steps without manual interaction

These steps can then be executed to install Terraform, Helm and optionally Visual Studio Code and GraphViz (if you want to visualize Terraform plans).

```shell
brew install terraform
brew install helm
brew install graphviz
brew install wget
brew install --cask visual-studio-code
```

After installing Visual Studio Code, it is recommended to install the externsions for [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker) and [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools).

## Cloud CLIs

```shell
brew install awscli
brew install azure-cli
brew cask install google-cloud-sdk
```

After the install for the Google CLI, pay attention to the messages asking to add configuration to the user profile! For PowerShell, added the `bash` lines to `[User]/.bash_profile`.

Back to main [readme](../README.md)
