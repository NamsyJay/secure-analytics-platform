#!/usr/bin/env bash

set -Eeuo pipefail

ENVIRONMENT="${1:?Environment is required}"

echo "Running ${ENVIRONMENT} smoke tests"

kubectl rollout status deployment/jupyterhub \
  --namespace analytics \
  --timeout=10m

kubectl get nodes
kubectl get pods --namespace analytics

FAILED_PODS="$(
  kubectl get pods \
    --namespace analytics \
    --field-selector=status.phase=Failed \
    --no-headers 2>/dev/null |
    wc -l
)"

if [[ "${FAILED_PODS}" -gt 0 ]]; then
  echo "One or more pods are in Failed state."
  exit 1
fi

echo "${ENVIRONMENT} smoke tests passed."