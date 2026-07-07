#!/usr/bin/env bash
#
# cleanup.sh - Tear down the demo. Uninstalls Radius and (optionally) deletes
#              the IRSA IAM role and the EKS cluster so you stop paying for AWS
#              resources.
#
# Usage:
#   ./cleanup.sh                     # uninstall Radius + delete IAM + delete EKS cluster
#   DELETE_AWS=false ./cleanup.sh    # only uninstall Radius, keep all AWS resources
#
set -euo pipefail

# ---- Configuration (override via environment variables) ---------------------
CLUSTER_NAME="${CLUSTER_NAME:-radius-quickstart-eks}"
AWS_REGION="${AWS_REGION:-us-west-2}"
ROLE_NAME="${ROLE_NAME:-radius-quickstart-irsa}"
ROLE_POLICY_ARN="${ROLE_POLICY_ARN:-arn:aws:iam::aws:policy/PowerUserAccess}"
DELETE_AWS="${DELETE_AWS:-true}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- Uninstall Radius -------------------------------------------------------
if command -v rad >/dev/null 2>&1; then
  say "Uninstalling Radius from the cluster (purging all data)"
  rad uninstall kubernetes --purge || true
else
  echo "rad CLI not found; skipping Radius uninstall."
fi

if [[ "${DELETE_AWS}" != "true" ]]; then
  echo "DELETE_AWS=false: leaving all AWS resources in place."
  say "Cleanup complete"
  exit 0
fi

command -v aws >/dev/null || { echo "aws not found; cannot delete AWS resources."; exit 1; }

# ---- Delete the IRSA IAM role ----------------------------------------------
# A role must have all managed policies detached before it can be deleted.
say "Deleting IRSA IAM role '${ROLE_NAME}' (if present)"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  read -r -p "Delete IAM role '${ROLE_NAME}'? [y/N] " reply
  if [[ "${reply}" =~ ^[Yy]$ ]]; then
    # Detach all attached managed policies, then delete any inline policies.
    for arn in $(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
                  --query "AttachedPolicies[].PolicyArn" --output text); do
      aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${arn}" || true
    done
    for p in $(aws iam list-role-policies --role-name "${ROLE_NAME}" \
                --query "PolicyNames[]" --output text); do
      aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${p}" || true
    done
    aws iam delete-role --role-name "${ROLE_NAME}" && echo "  deleted '${ROLE_NAME}'."
  else
    echo "  skipped IAM role deletion."
  fi
else
  echo "  not found; skipping."
fi

# ---- Delete the EKS cluster -------------------------------------------------
# 'eksctl delete cluster' tears down the cluster, its managed node group, and
# the supporting CloudFormation stacks (VPC, etc.).
say "Deleting EKS cluster '${CLUSTER_NAME}' in '${AWS_REGION}'"
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  read -r -p "Delete EKS cluster '${CLUSTER_NAME}' (this also removes its VPC/nodes)? [y/N] " reply
  if [[ "${reply}" =~ ^[Yy]$ ]]; then
    eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait
    echo "  cluster '${CLUSTER_NAME}' deleted."
  else
    echo "  skipped cluster deletion."
  fi
else
  echo "  cluster '${CLUSTER_NAME}' not found; skipping."
fi

say "Cleanup complete"
