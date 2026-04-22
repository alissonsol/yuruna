#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64 (Hyper-V)"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64 (UTM on Apple Silicon)"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo ""
echo -e "\e[1;36m>>> Installing Ollama...\e[0m"
curl -fsSL https://ollama.com/install.sh | sh
echo -e "\e[1;32m<<< Ollama installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Configuring Ollama to listen on all interfaces...\e[0m"
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf << 'OVERRIDE'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
OVERRIDE
sudo systemctl daemon-reload
sudo systemctl restart ollama
echo -e "\e[1;32m<<< Ollama configuration complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Pulling phi3:mini model...\e[0m"
ollama pull phi3:mini
echo -e "\e[1;32m<<< Model pull complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Verifying Ollama is working...\e[0m"
curl -s http://localhost:11434/api/generate   -d '{"model":"phi3:mini","prompt":"In one sentence, what causes network packet loss?","stream":false}'   | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
echo -e "\e[1;32m<<< Ollama verification complete.\e[0m"

echo ""
echo "FETCHED AND EXECUTED: ubuntu.server.ollama.sh"
