#!/usr/bin/env bash
#
# install-radius.sh - Install the Radius CLI (if needed), set up AWS IRSA
#                     (IAM Roles for Service Accounts) for Radius, install the
#                     Radius control plane onto the current kubectl context
#                     (your EKS cluster), and deploy the quickstart "demo" app.
#
# Prerequisites:
#   - kubectl context pointed at your EKS cluster (run ./setup-eks.sh first)
#   - For AWS IRSA: aws CLI configured, and the cluster's IAM OIDC provider
#     associated (setup-eks.sh does this with --with-oidc / associate-iam-oidc).
#
# Usage:
#   ./install-radius.sh                     # IRSA (default)
#   AWS_AUTH=accesskey ./install-radius.sh  # use a static access key/secret instead
#   AWS_AUTH=none ./install-radius.sh       # skip the AWS provider entirely
#
set -euo pipefail

# ---- Configuration (override via environment variables) ---------------------
# AWS_AUTH selects how Radius authenticates to AWS:
#   irsa      -> create an IAM role federated to the EKS OIDC provider (default)
#   accesskey -> you supply an access key / secret to 'rad init --full'
#   none      -> skip the AWS provider (the demo app needs no AWS resources)
AWS_AUTH="${AWS_AUTH:-irsa}"
CLUSTER_NAME="${CLUSTER_NAME:-radius-quickstart-eks}"
AWS_REGION="${AWS_REGION:-us-west-2}"
# IAM role + policy Radius assumes via IRSA. Created if missing.
ROLE_NAME="${ROLE_NAME:-radius-quickstart-irsa}"
# Managed policy attached to the role. PowerUserAccess covers most resources a
# Radius app might provision; scope this down for production use.
ROLE_POLICY_ARN="${ROLE_POLICY_ARN:-arn:aws:iam::aws:policy/PowerUserAccess}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Radius control-plane service accounts (in the radius-system namespace) that
# need to assume the IRSA role.
RADIUS_SERVICE_ACCOUNTS=(applications-rp bicep-de ucp dynamic-rp)

# ---- Pre-flight -------------------------------------------------------------
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }

say "Current kubectl context"
CONTEXT="$(kubectl config current-context)"
echo "${CONTEXT}"
echo "Radius will be installed onto this cluster."
read -r -p "Continue? [y/N] " reply
[[ "${reply}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ---- Install the Radius CLI -------------------------------------------------
if ! command -v rad >/dev/null 2>&1; then
  say "Installing the Radius CLI"
  curl -fsSL "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" | /bin/bash
else
  say "Radius CLI already installed"
fi
rad version

# ---- Set up AWS IRSA for Radius --------------------------------------------
# IRSA lets the Radius control-plane pods assume an IAM role using the EKS
# cluster's OIDC provider — NO static access keys. We create an IAM role whose
# trust policy federates the four radius-system service accounts to that OIDC
# provider, attach a permissions policy, and annotate the service accounts.
ROLE_ARN=""
AWS_ACCOUNT_ID=""
if [[ "${AWS_AUTH}" == "irsa" ]]; then
  command -v aws >/dev/null || { echo "ERROR: aws CLI required for AWS_AUTH=irsa."; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: configure AWS credentials first."; exit 1; }

  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

  say "Reading the EKS cluster OIDC issuer"
  OIDC_ISSUER="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query "cluster.identity.oidc.issuer" --output text)"
  OIDC_HOST="${OIDC_ISSUER#https://}"
  OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  echo "OIDC issuer       : ${OIDC_ISSUER}"
  echo "OIDC provider ARN : ${OIDC_PROVIDER_ARN}"

  # Build the StringEquals 'sub' list for the four service accounts, plus the
  # standard 'aud' = sts.amazonaws.com condition.
  SUBS=""
  for svc in "${RADIUS_SERVICE_ACCOUNTS[@]}"; do
    sub="\"system:serviceaccount:radius-system:${svc}\""
    SUBS="${SUBS:+${SUBS},}${sub}"
  done
  TRUST_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:aud": "sts.amazonaws.com",
          "${OIDC_HOST}:sub": [ ${SUBS} ]
        }
      }
    }
  ]
}
JSON
)"

  say "Creating IAM role '${ROLE_NAME}' (trusted by the radius-system service accounts)"
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    echo "Role exists — updating its trust policy."
    aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
      --policy-document "${TRUST_POLICY}"
  else
    aws iam create-role --role-name "${ROLE_NAME}" \
      --assume-role-policy-document "${TRUST_POLICY}" \
      --description "Radius quickstart IRSA role" >/dev/null
  fi
  ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

  say "Attaching permissions policy '${ROLE_POLICY_ARN}'"
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "${ROLE_POLICY_ARN}" || echo "  (policy may already be attached)"

  cat <<EOF

✅ AWS IRSA is ready. Use these in 'rad init --full':
     Credential kind : IRSA
     IAM role ARN    : ${ROLE_ARN}
     AWS region      : ${AWS_REGION}
     AWS account     : ${AWS_ACCOUNT_ID}
EOF
elif [[ "${AWS_AUTH}" == "accesskey" ]]; then
  say "Using AWS access key authentication"
  echo "When 'rad init --full' prompts for the AWS provider, choose 'Access Key'"
  echo "and paste your AWS Access Key ID and Secret Access Key."
else
  say "Skipping AWS provider setup (AWS_AUTH=none)"
  echo "The demo app deploys only a container and needs no AWS provider."
fi

# ---- Install the Radius control plane --------------------------------------
say "Installing the Radius control plane onto the EKS cluster"
rad install kubernetes

# IRSA requires the radius-system service accounts to carry the role-arn
# annotation so the AWS SDK in each pod assumes the role. Annotate them and
# restart the control-plane deployments so the change takes effect.
if [[ "${AWS_AUTH}" == "irsa" ]]; then
  say "Annotating radius-system service accounts with the IRSA role"
  for svc in "${RADIUS_SERVICE_ACCOUNTS[@]}"; do
    kubectl annotate serviceaccount "${svc}" -n radius-system \
      "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite || true
  done
  echo "Restarting radius-system deployments to pick up the annotation..."
  kubectl rollout restart deployment -n radius-system >/dev/null 2>&1 || true
  kubectl rollout status deployment -n radius-system --timeout=180s || true
fi

# ---- Initialize a Radius environment ---------------------------------------
say "Initializing a Radius environment"
if [[ "${AWS_AUTH}" == "irsa" ]]; then
  echo "When prompted, add an AWS provider, choose 'IRSA', and enter:"
  echo "    IAM role ARN : ${ROLE_ARN}"
  echo "    AWS region   : ${AWS_REGION}"
  echo "    AWS account  : ${AWS_ACCOUNT_ID}"
fi
# --full prompts for environment/namespace and (optionally) the AWS provider.
( cd "${APP_DIR}" && rad init --full )

# ---- Deploy the application -------------------------------------------------
say "Deploying the demo application (app.bicep)"
( cd "${APP_DIR}" && rad deploy app.bicep )

# ---- Show the application graph ---------------------------------------------
say "Application graph"
rad app graph -a demo || true

cat <<EOF

✅ Radius is installed and the demo app is deployed on EKS.

To browse the app locally, set up port-forwarding:

    rad run app.bicep        # from the app/ directory (Ctrl+C to stop)

Then open:
    App:       http://localhost:3000
    Dashboard: http://localhost:7007

When you are finished, tear everything down:

    ./scripts/cleanup.sh

EOF
