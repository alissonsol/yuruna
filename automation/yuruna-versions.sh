#!/bin/bash
# Version: 2026.11.16
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
export YURUNA_OPENTOFU_VERSION=1.13.9
# SHA-256 of tofu_<version>_linux_<arch>.tar.gz, from the release's
# tofu_<version>_SHA256SUMS (its .gpgsig verifies against OpenTofu's key
# E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80).
export YURUNA_OPENTOFU_SHA256_AMD64=b34b327cc1ef07178207b6f2cd1f5276537d3e5b7be316500f6dac50d4c0a857
export YURUNA_OPENTOFU_SHA256_ARM64=5dc196dde75b667e4806d358310ec96742774cd0993c54c1237efee5644b69b8
# An exact Helm release keeps guest provisioning on a repeatable version.
export YURUNA_HELM_VERSION=4.3.2
# SHA-256 of helm-v<version>-linux-<arch>.tar.gz, from get.helm.sh's
# <file>.sha256sum for that release.
export YURUNA_HELM_SHA256_AMD64=d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983
export YURUNA_HELM_SHA256_ARM64=df31cb61680ef728f82c770e5280dd565617bee6b039d37e85c677288be4bbb0
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
export YURUNA_NVM_VERSION=0.41.0
# SHA-256 of install.sh at tag v<version>, computed from raw.githubusercontent.com
# (upstream publishes no checksum for it).
export YURUNA_NVM_INSTALL_SHA256=045932fe05f0d4247c946f2ec0ec4026dbfd8ce88a5f67ea28d8ea833227f48b
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
