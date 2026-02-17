#!/bin/bash
set -euo pipefail

dnf update -y
dnf upgrade -y
dnf autoremove -y
