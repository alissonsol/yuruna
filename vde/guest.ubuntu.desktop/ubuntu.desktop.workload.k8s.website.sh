#!/bin/bash
set -e

# Fix kube permissions
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# Install mkcert CA
mkcert -install 2>/dev/null || true

# Start Docker registry if not running
docker start registry 2>/dev/null || docker run -d -p 5000:5000 --restart=always --name registry registry:2

# Clone yuruna if not present
if [ ! -d /home/ubuntu/yuruna ]; then
    git clone https://github.com/alissonsol/yuruna.git /home/ubuntu/yuruna
fi

# Run Set-Resource
cd /home/ubuntu/yuruna/examples
pwsh ../automation/Set-Resource.ps1 website localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' /home/ubuntu/yuruna/examples/website/config/localhost/resources.output.yml | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# Build and push Docker image
cd /home/ubuntu/yuruna/examples/website/components/frontend/website
cp /home/ubuntu/.aspnet/https/aspnetapp.pfx .
docker build --progress=plain --rm --build-arg DEV=1 --no-cache -f Dockerfile -t "website/website:latest" .
docker tag website/website:latest localhost:5000/website/website:latest
docker push localhost:5000/website/website:latest

# Run Set-Component and Set-Workload
cd /home/ubuntu/yuruna/examples
pwsh ../automation/Set-Component.ps1 website localhost
pwsh ../automation/Set-Workload.ps1 website localhost
