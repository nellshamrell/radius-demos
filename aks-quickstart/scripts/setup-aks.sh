#!/usr/bin/env bash
#
# setup-aks.sh - Provision an AKS cluster suitable for running Radius and
#                wire up your local kubectl context to point at it.
#
# Prerequisites:
#   - Azure CLI (az) logged in:  az login
#   - kubectl installed
#
# Usage:
#   ./setup-aks.sh
#
# All values can be overridden via environment variables, e.g.:
#   RESOURCE_GROUP=my-rg LOCATION=westus2 ./setup-aks.sh
#
set -euo pipefail

# ---- Configuration (override via environment variables) ---------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-radius-quickstart-rg}"
LOCATION="${LOCATION:-eastus2}"
CLUSTER_NAME="${CLUSTER_NAME:-radius-quickstart-aks}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_DS2_v2}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"   # empty = AKS default (>=1.23.8 required by Radius)

# ---- Helpers ----------------------------------------------------------------
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- Pre-flight -------------------------------------------------------------
command -v az >/dev/null      || { echo "ERROR: Azure CLI (az) not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"; exit 1; }

say "Verifying Azure login"
if ! az account show >/dev/null 2>&1; then
  echo "You are not logged in to Azure. Running 'az login'..."
  az login
fi
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
echo "Using subscription: ${SUBSCRIPTION_ID}"

# ---- Select a usable region + VM size --------------------------------------
# Subscriptions can be restricted at TWO levels:
#   * VM size:  "The VM size of Standard_DS2_v2 is not allowed in your
#                subscription in location 'eastus'."
#   * Region:   sometimes EVERY size in a region is blocked for the
#               subscription (reasonCode 'NotAvailableForSubscription').
#
# 'az vm list-skus' must be called with --all to include sizes that carry
# restrictions, otherwise restricted VM sizes are silently omitted (the list
# comes back without any virtualMachines entries). A size is usable in a region
# only if it has NO restriction of type 'Location'. (Zone restrictions are fine
# for a basic AKS cluster that doesn't pin availability zones.)
#
# Each list-skus call downloads the whole regional catalog (~1-2 min), so we
# query once per region and stop at the first region that yields a usable size.

# Regions to try, in order. The requested LOCATION is tried first.
FALLBACK_REGIONS=(eastus2 westus2 westus3 centralus southcentralus westus)

# Preferred general-purpose sizes (2 vCPU), adequate for a Radius quickstart.
CANDIDATES=("${NODE_VM_SIZE}" Standard_D2s_v5 Standard_D2as_v5 Standard_DS2_v2 Standard_D2s_v3 Standard_B2ms)

# Echoes the first usable candidate size for region $1, or nothing.
pick_size_for_region() {
  local loc="$1"
  az vm list-skus --location "${loc}" --all -o json 2>/dev/null | \
    CANDS="${CANDIDATES[*]}" python3 -c '
import sys, json, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
vms = [x for x in data if x.get("resourceType") == "virtualMachines"]
usable = {
    x["name"] for x in vms
    if not any(r.get("type") == "Location" for r in (x.get("restrictions") or []))
}
for c in os.environ.get("CANDS", "").split():
    if c in usable:
        print(c)
        break
'
}

CHOSEN_REGION=""
CHOSEN_SIZE=""
TRY_REGIONS=("${LOCATION}")
for r in "${FALLBACK_REGIONS[@]}"; do
  [[ "${r}" == "${LOCATION}" ]] || TRY_REGIONS+=("${r}")
done

for r in "${TRY_REGIONS[@]}"; do
  say "Checking VM size availability in '${r}' (one-time, ~1-2 min)..."
  size="$(pick_size_for_region "${r}")"
  if [[ -n "${size}" ]]; then
    CHOSEN_REGION="${r}"
    CHOSEN_SIZE="${size}"
    if [[ "${r}" != "${LOCATION}" ]]; then
      echo "⚠️  '${LOCATION}' has no usable VM sizes for this subscription."
      echo "➡️  Falling back to region '${r}'."
    fi
    echo "✅ Using region '${CHOSEN_REGION}' with VM size '${CHOSEN_SIZE}'."
    break
  fi
  echo "   No usable preferred size in '${r}'."
done

if [[ -z "${CHOSEN_REGION}" ]]; then
  echo "ERROR: Could not find a usable region/VM size for this subscription."
  echo "Inspect availability manually, e.g.:"
  echo "  az vm list-skus --location <region> --all --resource-type virtualMachines \\"
  echo "    --query \"[?!(restrictions[?type=='Location'])].name\" -o tsv | sort -u"
  echo "Then re-run with overrides, e.g.:"
  echo "  LOCATION=<region> NODE_VM_SIZE=<size> ./scripts/setup-aks.sh"
  exit 1
fi

LOCATION="${CHOSEN_REGION}"
NODE_VM_SIZE="${CHOSEN_SIZE}"

# ---- Create the resource group ---------------------------------------------
say "Creating resource group '${RESOURCE_GROUP}' in '${LOCATION}'"
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --output none

# ---- Create the AKS cluster -------------------------------------------------
# Notes for Radius compatibility:
#   * AKS-managed AAD is NOT supported by Radius, so we do not enable it.
#   * Radius requires Kubernetes >= 1.23.8 (AKS defaults satisfy this).
say "Creating AKS cluster '${CLUSTER_NAME}' with node size '${NODE_VM_SIZE}'"
echo "⏳ This typically takes 5-10 minutes. Azure shows a 'Running ..' spinner below."
echo "   It is NOT hung — leave it running. (First-ever AKS in a subscription can take longer"
echo "   while Azure registers the Microsoft.ContainerService provider.)"
AKS_ARGS=(
  --resource-group "${RESOURCE_GROUP}"
  --name "${CLUSTER_NAME}"
  --node-count "${NODE_COUNT}"
  --node-vm-size "${NODE_VM_SIZE}"
  --generate-ssh-keys
  # Workload Identity prerequisites — required if you want Radius to access
  # Azure via Azure Workload Identity (see scripts/install-radius.sh). Enabling
  # them at create time is free and avoids a slow 'az aks update' later.
  --enable-oidc-issuer
  --enable-workload-identity
  --output table
)
if [[ -n "${KUBERNETES_VERSION}" ]]; then
  AKS_ARGS+=(--kubernetes-version "${KUBERNETES_VERSION}")
fi
az aks create "${AKS_ARGS[@]}"

# ---- Fetch credentials / set kubectl context -------------------------------
say "Fetching kubeconfig and setting it as your current context"
# WSL gotcha: if 'az' is the Windows CLI (under /mnt/...) but 'kubectl'/'rad' are
# Linux binaries, then 'az aks get-credentials' writes to the *Windows*
# kubeconfig (C:\Users\<you>\.kube\config) while kubectl/rad read the *Linux*
# one (~/.kube/config). The result is kubectl trying to reach a stale local
# cluster (e.g. 127.0.0.1:...). Detect this and merge the AKS context into the
# Linux kubeconfig so kubectl/rad "just work".
AZ_PATH="$(command -v az)"
if [[ "${AZ_PATH}" == /mnt/* ]] && command -v wslpath >/dev/null 2>&1; then
  echo "Detected Windows 'az' under WSL — merging AKS context into the Linux kubeconfig."
  WIN_PROFILE="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  WIN_CFG="${WIN_PROFILE}\\.kube\\aks-${CLUSTER_NAME}"
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${WIN_CFG}" \
    --overwrite-existing
  WSL_CFG="$(wslpath "${WIN_CFG}")"
  mkdir -p "${HOME}/.kube"
  [[ -f "${HOME}/.kube/config" ]] && cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak.$(date +%s)"
  KUBECONFIG="${HOME}/.kube/config:${WSL_CFG}" kubectl config view --flatten > "${HOME}/.kube/config.merged"
  mv "${HOME}/.kube/config.merged" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  rm -f "${WSL_CFG}"
  kubectl config use-context "${CLUSTER_NAME}"
else
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --overwrite-existing
fi

say "Verifying connectivity to the cluster"
kubectl cluster-info
kubectl get nodes

cat <<EOF

✅ AKS cluster is ready.

    Resource group : ${RESOURCE_GROUP}
    Cluster name   : ${CLUSTER_NAME}
    kubectl context: $(kubectl config current-context)

Next step: install Radius and deploy the app:

    ./scripts/install-radius.sh

EOF
