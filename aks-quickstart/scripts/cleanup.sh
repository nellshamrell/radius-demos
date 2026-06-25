#!/usr/bin/env bash
#
# cleanup.sh - Tear down the demo. Uninstalls Radius and (optionally) deletes
#              the AKS cluster, the Azure Workload Identity, and the resource
#              groups so you stop paying for Azure resources.
#
# Usage:
#   ./cleanup.sh                      # uninstall Radius + delete everything in Azure
#   DELETE_AZURE=false ./cleanup.sh   # only uninstall Radius, keep all Azure resources
#
set -euo pipefail

# Resource group holding the AKS cluster (from setup-aks.sh).
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-${RESOURCE_GROUP:-radius-quickstart-rg}}"
# Resource group holding Radius-deployed Azure resources + the workload-identity
# managed identity (from install-radius.sh).
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-radius-demo}"
WI_IDENTITY_NAME="${WI_IDENTITY_NAME:-radius-quickstart-wi}"
DELETE_AZURE="${DELETE_AZURE:-true}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- Uninstall Radius -------------------------------------------------------
if command -v rad >/dev/null 2>&1; then
  say "Uninstalling Radius from the cluster (purging all data)"
  rad uninstall kubernetes --purge || true
else
  echo "rad CLI not found; skipping Radius uninstall."
fi

if [[ "${DELETE_AZURE}" != "true" ]]; then
  echo "DELETE_AZURE=false: leaving all Azure resources in place."
  say "Cleanup complete"
  exit 0
fi

command -v az >/dev/null || { echo "az not found; cannot delete Azure resources."; exit 1; }

# ---- Delete the Workload Identity ------------------------------------------
# Deleting the managed identity also removes its federated credentials. Role
# assignments scoped to the resource group are removed when the RG is deleted,
# but we delete the identity explicitly in case the RG is being kept.
say "Deleting workload-identity managed identity '${WI_IDENTITY_NAME}' (if present)"
if az identity show -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" >/dev/null 2>&1; then
  az identity delete -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" && \
    echo "  deleted '${WI_IDENTITY_NAME}'."
else
  echo "  not found; skipping."
fi

# ---- Delete the resource groups --------------------------------------------
delete_rg() {
  local rg="$1" desc="$2"
  if ! az group show -n "${rg}" >/dev/null 2>&1; then
    echo "  resource group '${rg}' not found; skipping."
    return
  fi
  read -r -p "Delete resource group '${rg}' (${desc})? [y/N] " reply
  if [[ "${reply}" =~ ^[Yy]$ ]]; then
    az group delete --name "${rg}" --yes --no-wait
    echo "  deletion started. Track with: az group show -n ${rg}"
  else
    echo "  skipped '${rg}'."
  fi
}

say "Deleting Azure resource groups (runs in background)"
delete_rg "${AKS_RESOURCE_GROUP}" "AKS cluster"
delete_rg "${AZURE_RESOURCE_GROUP}" "Radius Azure resources + workload identity"

say "Cleanup complete"
