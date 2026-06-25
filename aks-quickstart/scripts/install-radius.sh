#!/usr/bin/env bash
#
# install-radius.sh - Install the Radius CLI (if needed), set up Azure Workload
#                     Identity for Radius, install the Radius control plane onto
#                     the current kubectl context (your AKS cluster), and deploy
#                     the quickstart "demo" application.
#
# Prerequisites:
#   - kubectl context pointed at your AKS cluster (run ./setup-aks.sh first)
#   - For Azure Workload Identity: az CLI logged in, and the AKS cluster created
#     with --enable-oidc-issuer --enable-workload-identity (setup-aks.sh does this)
#
# Usage:
#   ./install-radius.sh
#
# Azure Workload Identity is set up by default. To skip it (e.g. the demo app
# only deploys a container and needs no Azure resources):
#   AZURE_WI=false ./install-radius.sh
#
set -euo pipefail

# ---- Configuration (override via environment variables) ---------------------
AZURE_WI="${AZURE_WI:-true}"                 # set false to skip Azure provider
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-${RESOURCE_GROUP:-radius-quickstart-rg}}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-${CLUSTER_NAME:-radius-quickstart-aks}}"
# Resource group where Radius will deploy Azure resources (and where the
# workload-identity managed identity lives). Created if missing.
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-radius-demo}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus2}"
WI_IDENTITY_NAME="${WI_IDENTITY_NAME:-radius-quickstart-wi}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
# Windows 'az' under WSL appends CR to -o tsv output; strip it everywhere.
clean() { tr -d '\r\n'; }

# Radius control-plane service accounts (in the radius-system namespace) that
# need a federated credential to use Azure Workload Identity.
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

# ---- Set up Azure Workload Identity for Radius ------------------------------
# This creates a user-assigned managed identity (UAMI) and federates the Radius
# control-plane service accounts to it, so Radius can authenticate to Azure with
# NO client secret.
#
# Why a UAMI and not an app registration / service principal?
#   * Corp Entra tenants commonly forbid client-secret credentials on app
#     registrations ("Credential type not allowed as per assigned policy").
#   * They also restrict which OIDC issuers an *app registration* may federate
#     to, which blocks the AKS issuer ("FederatedIdentityCredential.Issuer ...
#     not allowed as per assigned policy").
#   * A user-assigned managed identity is not subject to those app policies and
#     is the standard AKS Workload Identity pattern.
WI_CLIENT_ID=""
WI_TENANT_ID=""
if [[ "${AZURE_WI}" == "true" ]]; then
  command -v az >/dev/null || { echo "ERROR: az CLI required for AZURE_WI=true."; exit 1; }
  az account show >/dev/null 2>&1 || { echo "ERROR: run 'az login' first."; exit 1; }

  SUBSCRIPTION_ID="$(az account show --query id -o tsv | clean)"
  WI_TENANT_ID="$(az account show --query tenantId -o tsv | clean)"

  say "Ensuring AKS OIDC issuer + workload identity are enabled"
  OIDC_ISSUER="$(az aks show -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" \
    --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null | clean || true)"
  if [[ -z "${OIDC_ISSUER}" ]]; then
    echo "OIDC issuer not enabled yet — enabling now (a few minutes)..."
    az aks update -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" \
      --enable-oidc-issuer --enable-workload-identity -o none
    OIDC_ISSUER="$(az aks show -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" \
      --query oidcIssuerProfile.issuerUrl -o tsv | clean)"
  fi
  echo "OIDC issuer: ${OIDC_ISSUER}"

  say "Ensuring resource group '${AZURE_RESOURCE_GROUP}' exists"
  az group show -n "${AZURE_RESOURCE_GROUP}" >/dev/null 2>&1 || \
    az group create -n "${AZURE_RESOURCE_GROUP}" -l "${AZURE_LOCATION}" -o none

  say "Creating user-assigned managed identity '${WI_IDENTITY_NAME}'"
  az identity show -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" >/dev/null 2>&1 || \
    az identity create -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" -l "${AZURE_LOCATION}" -o none
  WI_CLIENT_ID="$(az identity show -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" --query clientId -o tsv | clean)"
  WI_PRINCIPAL_ID="$(az identity show -g "${AZURE_RESOURCE_GROUP}" -n "${WI_IDENTITY_NAME}" --query principalId -o tsv | clean)"

  say "Creating federated credentials for Radius service accounts"
  for svc in "${RADIUS_SERVICE_ACCOUNTS[@]}"; do
    fic="radius-${svc}"
    echo "  - ${fic} (system:serviceaccount:radius-system:${svc})"
    az identity federated-credential show --name "${fic}" \
        --identity-name "${WI_IDENTITY_NAME}" -g "${AZURE_RESOURCE_GROUP}" >/dev/null 2>&1 || \
      az identity federated-credential create \
        --name "${fic}" \
        --identity-name "${WI_IDENTITY_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --issuer "${OIDC_ISSUER}" \
        --subject "system:serviceaccount:radius-system:${svc}" \
        --audiences "api://AzureADTokenExchange" -o none
  done

  say "Granting the identity Contributor on '${AZURE_RESOURCE_GROUP}'"
  az role assignment create \
    --assignee-object-id "${WI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}" \
    -o none 2>&1 || echo "  (role assignment may already exist)"

  cat <<EOF

✅ Azure Workload Identity is ready. Use these in 'rad init --full':
     Credential kind : Workload Identity
     Client ID / appId: ${WI_CLIENT_ID}
     Tenant ID        : ${WI_TENANT_ID}
     Subscription     : ${SUBSCRIPTION_ID}
     Resource group   : ${AZURE_RESOURCE_GROUP}
EOF
else
  say "Skipping Azure Workload Identity setup (AZURE_WI=false)"
  echo "The demo app deploys only a container and needs no Azure provider."
fi

# ---- Initialize Radius on the AKS cluster -----------------------------------
# 'rad install kubernetes' installs the control plane onto the current context.
# 'rad init' below then creates an environment and wires up local config.
say "Installing the Radius control plane onto the AKS cluster"
rad install kubernetes

say "Initializing a Radius environment"
if [[ "${AZURE_WI}" == "true" ]]; then
  echo "When prompted, choose to add an Azure provider, select 'Workload Identity',"
  echo "and enter:"
  echo "    Client ID / appId : ${WI_CLIENT_ID}"
  echo "    Tenant ID         : ${WI_TENANT_ID}"
fi
# --full prompts for environment/namespace and (optionally) the Azure provider.
( cd "${APP_DIR}" && rad init --full )

# ---- Deploy the application -------------------------------------------------
say "Deploying the demo application (app.bicep)"
( cd "${APP_DIR}" && rad deploy app.bicep )

# ---- Show the application graph ---------------------------------------------
say "Application graph"
rad app graph -a demo || true

cat <<EOF

✅ Radius is installed and the demo app is deployed on AKS.

To browse the app locally, set up port-forwarding:

    rad run app.bicep        # from the app/ directory (Ctrl+C to stop)

Then open:
    App:       http://localhost:3000
    Dashboard: http://localhost:7007

When you are finished, tear everything down:

    ./scripts/cleanup.sh

EOF
