#!/usr/bin/env bash

set -Eeuo pipefail

ENVIRONMENT="${1:?Environment is required}"
RELEASE_SHA="${2:?Release SHA is required}"

case "${ENVIRONMENT}" in
  dev|test|prod)
    ;;
  *)
    echo "Unsupported environment: ${ENVIRONMENT}" >&2
    exit 1
    ;;
esac

TF_DIRECTORY="infrastructure/environments/${ENVIRONMENT}"
TFVARS_FILE="${ENVIRONMENT}.tfvars"

echo "Deploying release ${RELEASE_SHA} to ${ENVIRONMENT}"

terraform -chdir="${TF_DIRECTORY}" init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="region=${AWS_REGION}"

terraform -chdir="${TF_DIRECTORY}" plan \
  -var-file="${TFVARS_FILE}" \
  -var="release_sha=${RELEASE_SHA}" \
  -out=tfplan

terraform -chdir="${TF_DIRECTORY}" apply \
  -auto-approve \
  tfplan

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER_NAME}"

if [[ -d "platform/helm/secure-analytics-platform" ]]; then
  helm upgrade --install secure-analytics-platform \
    platform/helm/secure-analytics-platform \
    --namespace analytics \
    --create-namespace \
    --values "platform/helm/secure-analytics-platform/values-${ENVIRONMENT}.yaml" \
    --set-string platform.releaseSha="${RELEASE_SHA}" \
    --atomic \
    --timeout 15m
fi

./scripts/smoke-test.sh "${ENVIRONMENT}"