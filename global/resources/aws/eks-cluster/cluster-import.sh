#!/usr/bin/env bash
# Version: 2026.09.27
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# The AWS CLI's default context name is the cluster ARN. Assign the caller's
# requested alias during import rather than renaming a nonexistent short name.
set -euo pipefail

: "${RESOURCE_REGION:?RESOURCE_REGION env var required}"
: "${CLUSTER_NAME:?CLUSTER_NAME env var required}"
: "${DESTINATION_CONTEXT:?DESTINATION_CONTEXT env var required}"

aws eks --region "$RESOURCE_REGION" update-kubeconfig --name "$CLUSTER_NAME" --alias "$DESTINATION_CONTEXT"
