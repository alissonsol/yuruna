#!/usr/bin/env bash
# Version: 2026.07.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/definition#defining-the-tofu-external-hook-shell-choice
# tofu data "external" hook: copy the kube context bundle at the stdin query's sourceContext under destinationContext inside ~/.kube/config.
set -euo pipefail

err() { printf 'context-copy: %s\n' "$*" >&2; exit 1; }

QUERY=$(cat)

read_field() {
    python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$QUERY" "$1"
}

src=$(read_field sourceContext)
dst=$(read_field destinationContext)

[ -n "$src" ] || err "sourceContext is empty"
[ -n "$dst" ] || err "destinationContext is empty"

cfg="${HOME}/.kube/config"
[ -f "$cfg" ] || err "K8S configuration not found: $cfg"
[ -s "$cfg" ] || err "K8S current configuration is empty: $cfg"

if ! kubectl --kubeconfig="$cfg" config get-contexts -o name | grep -Fxq "$src"; then
    err "K8S source context not found: $src"
fi

original=$(kubectl --kubeconfig="$cfg" config current-context 2>/dev/null || true)

# Strip any stale destination so the merge below adds a clean entry.
kubectl --kubeconfig="$cfg" config unset "contexts.${dst}" >/dev/null 2>&1 || true
kubectl --kubeconfig="$cfg" config unset "clusters.${dst}" >/dev/null 2>&1 || true
kubectl --kubeconfig="$cfg" config unset "users.${dst}" >/dev/null 2>&1 || true

# Minified --raw YAML embeds the source's certs/tokens; rename the three
# top-level names + the two intra-context references to the destination.
# Drop current-context so the merge does not stomp on our restore below.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

kubectl --kubeconfig="$cfg" config view --minify --raw=true --context "$src" -o yaml \
    | python3 -c '
import sys, yaml
dst = sys.argv[1]
data = yaml.safe_load(sys.stdin)
data["users"][0]["name"] = dst
data["clusters"][0]["name"] = dst
data["contexts"][0]["name"] = dst
data["contexts"][0]["context"]["cluster"] = dst
data["contexts"][0]["context"]["user"] = dst
data.pop("current-context", None)
yaml.safe_dump(data, sys.stdout, default_flow_style=False)
' "$dst" >"$tmp"

combined="${HOME}/.kube/config.yuruna"
rm -f "$combined"
KUBECONFIG="${cfg}:${tmp}" kubectl config view --flatten >"$combined"

[ -s "$combined" ] || err "K8S configuration problems. Try deleting invalid contexts: $cfg"

mv -f "$combined" "$cfg"

if [ -n "$original" ]; then
    kubectl --kubeconfig="$cfg" config use-context "$original" >/dev/null 2>&1 || true
fi

printf '{"destinationContext":"%s"}\n' "$dst"
