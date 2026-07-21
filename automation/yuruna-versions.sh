#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/network#defining-yuruna-versions-pins
# The ONLY place a guest dependency version literal lives. Guest scripts
# reference these variables, never the numbers. Keep it POSIX-simple -- one
# `export KEY=value` per line, unquoted, no spaces -- so
# Check-DependencyVersion.ps1 can parse it with a line regex instead of
# sourcing a shell. The linked section explains each pin and how to bump it.

export YURUNA_K8S_MINOR=1.36
export YURUNA_OPENTOFU_VERSION=1.12.4
export YURUNA_HELM_VERSION=4.2.3
export YURUNA_NVM_VERSION=0.40.6
export YURUNA_NODE_MAJOR=24
