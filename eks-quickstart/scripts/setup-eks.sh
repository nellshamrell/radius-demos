#!/usr/bin/env bash
#
# setup-eks.sh - Provision an AWS EKS cluster suitable for running Radius and
#                wire up your local kubectl context to point at it.
#
# Prerequisites:
#   - AWS CLI (aws) configured:   aws login   (or SSO / env credentials)
#   - eksctl installed:           https://eksctl.io/installation/
#   - kubectl installed
#
# Usage:
#   ./setup-eks.sh
#
# All values can be overridden via environment variables, e.g.:
#   AWS_REGION=us-east-1 NODE_COUNT=3 ./setup-eks.sh
#
set -euo pipefail

# ---- Configuration (override via environment variables) ---------------------
CLUSTER_NAME="${CLUSTER_NAME:-radius-quickstart-eks}"
AWS_REGION="${AWS_REGION:-us-west-2}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_TYPE="${NODE_TYPE:-t3.large}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.31}"   # Radius requires >= 1.23.8

# ---- Helpers ----------------------------------------------------------------
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- Pre-flight -------------------------------------------------------------
command -v aws >/dev/null     || { echo "ERROR: AWS CLI (aws) not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"; exit 1; }
command -v eksctl >/dev/null  || { echo "ERROR: eksctl not found. Install: https://eksctl.io/installation/"; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"; exit 1; }

say "Verifying AWS credentials"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or have expired."
  echo "Configure them with 'aws login' (or 'aws sso login') and try again."
  exit 1
fi
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Using AWS account: ${ACCOUNT_ID}"
echo "Region          : ${AWS_REGION}"

# ---- Create the EKS cluster -------------------------------------------------
# Notes for Radius compatibility:
#   * Radius requires Kubernetes >= 1.23.8 (the default here satisfies this).
#   * eksctl provisions a managed node group plus all supporting AWS resources
#     (VPC, subnets, security groups) via CloudFormation.
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  say "EKS cluster '${CLUSTER_NAME}' already exists in '${AWS_REGION}' — skipping create"
else
  say "Creating EKS cluster '${CLUSTER_NAME}' (${NODE_COUNT} x ${NODE_TYPE})"
  echo "⏳ This typically takes 15-20 minutes. eksctl streams CloudFormation progress below."
  echo "   It is NOT hung — leave it running."
  eksctl create cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --version "${KUBERNETES_VERSION}" \
    --nodegroup-name radius-ng \
    --node-type "${NODE_TYPE}" \
    --nodes "${NODE_COUNT}" \
    --managed \
    --with-oidc
fi

# ---- Associate the IAM OIDC provider ---------------------------------------
# IRSA (IAM Roles for Service Accounts) requires the cluster's OIDC provider to
# be registered as an IAM identity provider. '--with-oidc' above does this on
# create; we run it again (idempotent) to cover pre-existing clusters.
say "Ensuring the IAM OIDC provider is associated (required for IRSA)"
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --approve

# ---- Fetch credentials / set kubectl context -------------------------------
say "Fetching kubeconfig and setting it as your current context"
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

say "Verifying connectivity to the cluster"
kubectl cluster-info
kubectl get nodes

cat <<EOF

✅ EKS cluster is ready.

    Cluster name   : ${CLUSTER_NAME}
    Region         : ${AWS_REGION}
    kubectl context: $(kubectl config current-context)

Next step: install Radius and deploy the app:

    ./scripts/install-radius.sh

EOF
