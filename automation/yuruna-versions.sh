#!/bin/bash
# Version: 2026.07.03
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Single source of truth for the pinned upstream dependency versions used
# by guest provisioning scripts. Deployed to /usr/local/lib/yuruna/ by
# cloud-init (base64) alongside yuruna-retry.sh and sourced from it, so
# every guest script that sources the retry lib also sees these pins.
#
# To bump a dependency: run automation/Check-DependencyVersion.ps1, and when
# it reports a newer stable release upstream, edit the matching number here.
# This is the ONLY place a version number lives -- the guest scripts
# reference the variables, never the literals.
#
# Values are exported so they survive into the `bash << 'EOF'` heredocs the
# nvm/node guest scripts use (a child shell only inherits exported state).
# Keep this file POSIX-simple -- one `export KEY=value` per line, value
# unquoted and free of spaces -- so Check-DependencyVersion.ps1 can parse
# it with a line regex without sourcing a shell.
#
# --- See https://yuruna.link/network

# Kubernetes apt-repo minor track: pkgs.k8s.io/core:/stable:/v<minor>/deb.
# Bump only across a minor your kubeadm/kubelet/kubectl are validated on.
export YURUNA_K8S_MINOR=1.36

# OpenTofu release for the standalone installer's --opentofu-version. Pinning
# it means the installer never queries the rate-limited GitHub releases API
# for "latest" (an unauthenticated api.github.com call that 403s once many
# guests share one NAT egress IP), so the standalone fallback is deterministic.
export YURUNA_OPENTOFU_VERSION=1.12.3

# Node Version Manager release tag (github.com/nvm-sh/nvm) the Ubuntu guests
# fetch install.sh from. Amazon Linux uses nodesource instead (no nvm pin).
export YURUNA_NVM_VERSION=0.40.5

# Node.js major version. Ubuntu installs it via `nvm install <major>`; Amazon
# Linux via the nodesource `setup_<major>.x` bootstrap.
export YURUNA_NODE_MAJOR=24
