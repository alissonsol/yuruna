#!/usr/bin/env bash
# Version: 2026.06.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# tofu data "external" hook -- verify the local docker registry the
# workload bash starts BEFORE Set-Resource is actually running. POSIX
# only, no pwsh: a null_resource provisioner spawning pwsh here hits
# the FileLoadException trap class documented in
# feedback_pwsh_provisioner_assemblyname_flake.md (pwsh 7.6.x / .NET 10
# crashes at startup on System.Collections.Specialized with a truncated
# PublicKeyToken). Set-Resource's planfile-pinned apply means this
# script runs at plan time only, so the result is captured once and
# the apply pass never re-invokes it.
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
