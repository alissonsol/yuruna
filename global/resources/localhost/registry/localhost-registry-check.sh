#!/usr/bin/env bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 423507ea-3154-4742-a8e8-be62d752d021
#
# --- REGION: https://yuruna.link/42fa6f45-000f
# tofu data "external" hook: verify the local docker registry the workload bash starts BEFORE Set-Resource runs.
set -euo pipefail

# tofu sends a JSON object on stdin even when `query` is unset; drain it.
cat >/dev/null

state=$(docker inspect -f '{{.State.Running}}' registry 2>/dev/null || true)
if [ "$state" != "true" ]; then
    {
        echo "ERROR: docker container 'registry' is not running (State.Running='${state:-<container missing>}')."
        echo "       The workload bash script is expected to start it BEFORE Set-Resource runs, through"
        echo "       example_registry_prepare in project/tools/example-workload.sh:"
        echo "           docker start registry \\"
        echo "             || docker run -d -p 127.0.0.1:5000:5000 --restart=always --name registry registry:2.8.3"
        echo "       Run 'docker ps -a' and check dockerd logs to see why the container is gone."
    } >&2
    exit 1
fi

printf '{"running":"true","registryLocation":"localhost:5000"}\n'
