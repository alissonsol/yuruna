#!/usr/bin/env bash
# Version: 2026.06.12
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Imports the AKS cluster context into ~/.kube/config and renames it to
# the project's destination context. Bash + az/kubectl only, no pwsh:
# a pwsh local-exec provisioner here triggers the FileLoadException trap
# class documented in feedback_pwsh_provisioner_assemblyname_flake.md.
set -euo pipefail

: "${RESOURCE_GROUP:?RESOURCE_GROUP env var required}"
: "${CLUSTER_NAME:?CLUSTER_NAME env var required}"
: "${DESTINATION_CONTEXT:?DESTINATION_CONTEXT env var required}"

az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
kubectl config rename-context "$CLUSTER_NAME" "$DESTINATION_CONTEXT"
