#!/bin/bash
# Version: 2026.10.31
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42b6e20a-0c70-4d03-ad67-d64c73c4ba78
# Dependency pins for guest provisioning; service-VM seeds carry their own pins.
# Keep each export unquoted and without spaces for Check-DependencyVersion.ps1 parsing.
# A *_SHA256* pin belongs to the version pin above it: bumping the version means
# replacing its digests from the source the comment names.
# --- REGION: https://yuruna.link/4220a755-0008
# Select one stable Kubernetes minor; its package repository supplies
# patch updates without moving the cluster to another minor.
export YURUNA_K8S_MINOR=1.37
# Verify the exact stable release after standalone installation and before
# reusing an installed binary.
export YURUNA_OPENTOFU_VERSION=1.13.1
# SHA-256 of tofu_<version>_linux_<arch>.tar.gz, from the release's
# tofu_<version>_SHA256SUMS (its .gpgsig verifies against OpenTofu's key
# E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80).
export YURUNA_OPENTOFU_SHA256_AMD64=378ada19d4bc70c43732004e8159be771b23b9a5afdf059e5f8a2b3fa2c70a69
export YURUNA_OPENTOFU_SHA256_ARM64=9c1ef375aa1852db0b2888aa921b640c71f8140d4682aa4fec99378a64fa7dc3
# An exact Helm release keeps guest provisioning on a repeatable version.
export YURUNA_HELM_VERSION=4.3.1
# SHA-256 of helm-v<version>-linux-<arch>.tar.gz, from get.helm.sh's
# <file>.sha256sum for that release.
export YURUNA_HELM_SHA256_AMD64=0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
export YURUNA_HELM_SHA256_ARM64=8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88
# One flannel release keeps the CNI manifest, and the images the caching proxy
# warms from it, the same across builds.
export YURUNA_FLANNEL_VERSION=0.28.10
# SHA-256 of Documentation/kube-flannel.yml at tag v<version>, computed from
# raw.githubusercontent.com (upstream publishes no checksum for that file).
export YURUNA_FLANNEL_MANIFEST_SHA256=944a3c1f925f117727a1b7272a323c80965da642498397ec7e6ea9bef0f9e6c5
# An exact mkcert release; the Ubuntu package stays the fallback.
export YURUNA_MKCERT_VERSION=1.4.4
# SHA-256 of the GitHub release asset mkcert-v<version>-linux-<arch>, computed
# from the asset (upstream publishes no checksum file).
export YURUNA_MKCERT_SHA256_AMD64=6d31c65b03972c6dc4a14ab429f2928300518b26503f58723e532d1b0a3bbb52
export YURUNA_MKCERT_SHA256_ARM64=b98f2cc69fd9147fe4d405d859c57504571adec0d3611c3eefd04107c7ac00d0
# A fixed nvm installer keeps installation behavior independent of
# updates within the chosen Node major.
export YURUNA_NVM_VERSION=0.40.8
# SHA-256 of install.sh at tag v<version>, computed from raw.githubusercontent.com
# (upstream publishes no checksum for it).
export YURUNA_NVM_INSTALL_SHA256=48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e
# The dotnet/install-scripts commit whose src/dotnet-install.sh the Linux code
# guests run; the script itself follows the .NET LTS channel. Keep the
# Windows code workload's commit the same.
export YURUNA_DOTNET_INSTALL_COMMIT=4a37a9f9d1a061fc389d6515100336db4e51710e
# SHA-256 of src/dotnet-install.sh at that commit, computed from
# raw.githubusercontent.com (upstream publishes no checksum for it).
export YURUNA_DOTNET_INSTALL_SHA256=082f7685e156738a1b2e2ed8381a621870d4ce8e8c59278034556f05c186eb2e
# Pin an LTS major; installers take updates within that line without
# changing the runtime major used by OpenClaw and n8n.
export YURUNA_NODE_MAJOR=24
