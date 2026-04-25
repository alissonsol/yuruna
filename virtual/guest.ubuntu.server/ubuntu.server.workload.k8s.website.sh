#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1


# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Fix kube permissions
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

# Install mkcert CA
mkcert -install 2>/dev/null || true

# Start Docker registry if not running. Pulls via public.ecr.aws mirror to avoid
# Docker Hub's anonymous pull rate limit, which had been the top cause of
# workload-test failures.
REGISTRY_IMAGE="public.ecr.aws/docker/library/registry:2"
if ! docker start registry 2>/dev/null; then
    if ! docker_out=$(docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE" 2>&1); then
        echo "docker run registry failed:" >&2
        echo "$docker_out" >&2
        if echo "$docker_out" | grep -qiE 'pull rate limit|toomanyrequests|429 Too Many Requests'; then
            echo "" >&2
            echo "ERROR: Registry image pull hit a rate limit." >&2
            echo "       Image: $REGISTRY_IMAGE" >&2
            echo "       The mirror is throttling anonymous pulls from this IP." >&2
            echo "       Options: wait and retry, switch to a different mirror, or authenticate." >&2
            echo "" >&2
        fi
        exit 1
    fi
fi

# Clone yuruna if not present
if [ ! -d "$REAL_HOME/yuruna" ]; then
    for attempt in 1 2 3; do
        git clone https://github.com/alissonsol/yuruna.git "$REAL_HOME/yuruna" && break
        echo "git clone attempt $attempt failed"
        rm -rf "$REAL_HOME/yuruna"
        [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna" ]; then
        echo "git clone failed after 3 attempts" >&2
        exit 1
    fi
fi

# Run Set-Resource
echo "==== Set-Resource ===="
cd "$REAL_HOME/yuruna/projects/examples"
pwsh ../../automation/Set-Resource.ps1 website localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/projects/examples/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# Build and push Docker image
cd "$REAL_HOME/yuruna/projects/examples/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .
docker build --progress=plain --rm --build-arg DEV=1 --no-cache -f Dockerfile -t "website/website:latest" .
docker tag website/website:latest localhost:5000/website/website:latest
docker push localhost:5000/website/website:latest

# Run Set-Component and Set-Workload
cd "$REAL_HOME/yuruna/projects/examples"
echo "==== Set-Component ===="
pwsh ../../automation/Set-Component.ps1 website localhost
echo "==== Set-Workload ===="
pwsh ../../automation/Set-Workload.ps1 website localhost
