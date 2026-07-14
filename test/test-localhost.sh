#!/bin/bash
# Version: 2026.07.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Probe localhost HTTP and print the status line.
# Retries because ingress-nginx serves 503 until both the controller
# pod and the website Service Endpoints are Ready, which can lag a
# Node=Ready signal by tens of seconds on a cold cluster.
deadline=$((SECONDS + 180))
last_code=""
while [ "$SECONDS" -lt "$deadline" ]; do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' http://localhost)
  if [ "$code" = "200" ]; then
    echo "HTTP/1.1 200 OK"
    exit 0
  fi
  last_code="$code"
  echo "  ${SECONDS}s: code=${code:-none}"
  sleep 5
done
# -sS on the failure path: silent on success, but surface the actual transport
# error (connection refused, TLS, name resolution) instead of swallowing it.
echo "!! 180s deadline reached, last code: ${last_code:-none}"
curl -k -sSI http://localhost 2>&1 | head -n 5
echo "--- kubectl get pods,svc,ingress -A | tail ---"
kubectl get pods,svc,ingress -A 2>&1 | tail
exit 1
