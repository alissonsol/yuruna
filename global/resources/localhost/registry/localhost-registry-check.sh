#!/usr/bin/env bash
# Version: 2026.07.17
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/definition#defining-the-tofu-external-hook-shell-choice
# tofu data "external" hook: verify the local docker registry the workload bash starts BEFORE Set-Resource runs.
set -euo pipefail

# tofu sends a JSON object on stdin even when `query` is unset; drain it.
cat >/dev/null

state=$(docker inspect -f '{{.State.Running}}' registry 2>/dev/null || true)
if [ "$state" != "true" ]; then
    {
        echo "ERROR: docker container 'registry' is not running (State.Running='${state:-<container missing>}')."
        echo "       The workload bash script is expected to start it BEFORE Set-Resource runs, e.g."
        echo "       project/example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh:"
        echo "           docker start registry \\"
        echo "             || docker run -d -p 5000:5000 --restart=always --name registry registry:2"
        echo "       Run 'docker ps -a' and check dockerd logs to see why the container is gone."
    } >&2
    exit 1
fi

printf '{"running":"true","registryLocation":"localhost:5000"}\n'
