# Radius Quickstart on Azure Kubernetes Service (AKS)

This demo walks you through deploying your first [Radius](https://radapp.io) application —
the same containerized **Todo List / demo** app from the
[official Radius quickstart](https://docs.radapp.io/quick-start/) — but instead of running on a
local Kubernetes cluster (k3d/kind), it runs on a real **AKS cluster on Azure**.

By the end you will have:

- An AKS cluster running in your Azure subscription
- The Radius control plane installed on that cluster
- The `demo` container application deployed and reachable via port-forwarding
- A clean teardown path so you don't keep paying for Azure resources

---

## Architecture at a glance

```
   Your workstation                       Azure
  ┌────────────────┐               ┌───────────────────────────┐
  │  rad CLI       │   kubectl     │  Resource Group            │
  │  kubectl       │──────────────▶│   └─ AKS cluster           │
  │  az CLI        │   (kubeconfig)│        ├─ radius-system ns  │  ← Radius control plane
  └────────────────┘               │        └─ default-* ns     │  ← your app's pods/services
                                   └───────────────────────────┘
```

Radius installs into the `radius-system` namespace and deploys your application's
Kubernetes objects (Deployment, Service, ServiceAccount, Role, RoleBinding) into the
cluster, exactly as it would locally — the only difference is the cluster lives in Azure.

---

## Prerequisites

You need the following installed and configured on your workstation:

| Tool | Purpose | Install |
|------|---------|---------|
| **Azure CLI** (`az`) | Create and manage the AKS cluster | <https://learn.microsoft.com/cli/azure/install-azure-cli> |
| **kubectl** | Talk to the cluster | <https://kubernetes.io/docs/tasks/tools/> |
| **Radius CLI** (`rad`) | Install Radius and deploy the app (the script installs this for you if missing) | <https://docs.radapp.io/installation/> |
| An **Azure subscription** | Hosts the AKS cluster | <https://azure.microsoft.com/free/> |

Then log in to Azure:

```bash
az login
# If you have multiple subscriptions, select the one to use:
az account set --subscription "<your-subscription-id-or-name>"
```

> **Cost note:** An AKS cluster with 2 `Standard_DS2_v2` nodes incurs charges while running.
> Run [`scripts/cleanup.sh`](scripts/cleanup.sh) when you're done to delete everything.

> **Radius + AKS caveat:** [AKS-managed Microsoft Entra (AAD)](https://learn.microsoft.com/azure/aks/managed-aad)
> is **not currently supported** by Radius. The setup script does **not** enable it.

---

## Step 1 — Provision the AKS cluster

From the `aks-quickstart/` directory:

```bash
./scripts/setup-aks.sh
```

This script:

1. Verifies you're logged in to Azure (`az login` if not).
2. Creates a resource group (`radius-quickstart-rg` by default).
3. Creates an AKS cluster (`radius-quickstart-aks`, 2 nodes) — Radius requires Kubernetes ≥ 1.23.8,
   which the AKS default satisfies.
4. Runs `az aks get-credentials` to merge the cluster into your kubeconfig and set it as the
   current context.
5. Verifies connectivity with `kubectl get nodes`.

You can customize the deployment with environment variables:

```bash
RESOURCE_GROUP=my-rg LOCATION=westus2 CLUSTER_NAME=my-aks NODE_COUNT=3 ./scripts/setup-aks.sh
```

> **VM size / region restrictions:** Some subscriptions are restricted at the VM-size
> level (e.g. `The VM size of Standard_DS2_v2 is not allowed in your subscription in
> location 'eastus'`) — and sometimes **every** size in a region is blocked
> (`NotAvailableForSubscription`). The script handles both: it checks each region for a
> usable size and, if the requested `LOCATION` has none, **automatically falls back** to
> another region (`eastus2`, `westus2`, `westus3`, `centralus`, `southcentralus`, `westus`).
> Each availability check downloads the regional VM catalog and takes ~1-2 minutes.
> To skip the search, pin a known-good region and size yourself:
>
> ```bash
> LOCATION=eastus2 NODE_VM_SIZE=Standard_DS2_v2 ./scripts/setup-aks.sh
> ```

Under the hood it runs the equivalent of:

```bash
az group create --name radius-quickstart-rg --location eastus
az aks create --resource-group radius-quickstart-rg --name radius-quickstart-aks \
  --node-count 2 --node-vm-size Standard_DS2_v2 --generate-ssh-keys
az aks get-credentials --resource-group radius-quickstart-rg --name radius-quickstart-aks
```

Confirm your context points at AKS:

```bash
kubectl config current-context   # -> radius-quickstart-aks
```

---

## Step 2 — Install Radius and deploy the app

```bash
./scripts/install-radius.sh
```

This script:

1. Installs the Radius CLI if `rad` isn't already on your `PATH`.
2. Confirms the target cluster (your AKS context) before proceeding.
3. **Sets up Azure Workload Identity** (unless `AZURE_WI=false`): creates a user-assigned
   managed identity, federates the Radius control-plane service accounts to it, and grants
   it Contributor on the Azure resource group (see below).
4. Installs the Radius control plane onto AKS with `rad install kubernetes`.
5. Creates a Radius environment with `rad init --full`.
6. Deploys [`app/app.bicep`](app/app.bicep) with `rad deploy`.
7. Prints the application graph with `rad app graph`.

### Azure provider: which credential kind?

`rad init --full` asks how Radius should authenticate to Azure — **Service Principal** or
**Workload Identity**. The script sets up **Workload Identity** because it uses **no client
secret**, which is required in Entra tenants that restrict secrets/issuers (very common in
corp tenants). When prompted, choose **Workload Identity** and paste the **Client ID** and
**Tenant ID** the script prints.

> **Why a managed identity, not a service principal?** Many Entra tenants block client-secret
> credentials on app registrations (`Credential type not allowed as per assigned policy`) and
> restrict which OIDC issuers an app registration may federate to (`FederatedIdentityCredential.Issuer
> ... not allowed`). A **user-assigned managed identity** sidesteps both policies and is the
> standard AKS Workload Identity pattern. The script creates four federated credentials — one
> each for the Radius `applications-rp`, `bicep-de`, `ucp`, and `dynamic-rp` service accounts in
> the `radius-system` namespace.

> **This demo doesn't actually need Azure.** `app.bicep` only deploys a container — it
> provisions zero Azure resources. To skip the Azure provider entirely:
>
> ```bash
> AZURE_WI=false ./scripts/install-radius.sh
> ```
>
> Workload Identity matters once your app declares real Azure resources (Cosmos DB, Service
> Bus, etc.).

The application definition is the standard quickstart container:

```bicep
extension radius

@description('The Radius Application ID. Injected automatically by the rad CLI.')
param application string

resource demo 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'demo'
  properties: {
    application: application
    container: {
      image: 'ghcr.io/radius-project/samples/demo:latest'
      ports: {
        web: {
          containerPort: 3000
        }
      }
    }
  }
}
```

---

## Step 3 — Browse the application

`rad deploy` creates the resources but does not forward ports. To view the app and the
Radius dashboard locally, run (from the `app/` directory):

```bash
cd app
rad run app.bicep
```

`rad run` deploys the app, sets up port-forwarding, and streams container logs. Then open:

- **App UI:** <http://localhost:3000>
- **Radius Dashboard:** <http://localhost:7007>

Press `Ctrl+C` to stop port-forwarding.

### Inspect the application graph

```bash
rad app graph -a demo
```

Expected output:

```
Displaying application: demo

Name: demo (Applications.Core/containers)
Connections: (none)
Resources:
  demo (apps/Deployment)
  demo (core/Service)
  demo (core/ServiceAccount)
  demo (rbac.authorization.k8s.io/Role)
  demo (rbac.authorization.k8s.io/RoleBinding)
```

You can also confirm the underlying Kubernetes objects directly on AKS:

```bash
kubectl get deployment,service,pod -n demo-app
```

---

## Step 4 — Prove it's really running on AKS (not a local cluster)

Since you reach the app at `http://localhost:3000`, viewers may assume it's running locally —
but `localhost` is only the `rad run` **port-forward tunnel**. The container actually runs on
an Azure VM in your AKS cluster. The quickest way to prove it (no app changes) is to show the
**nodes** the workload runs on. In a second terminal:

```bash
kubectl get nodes -o wide
```

The output is unmistakably AKS, not kind/k3d/Docker Desktop:

```
NAME                                STATUS   ROLES   AGE   VERSION   ...   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
aks-nodepool1-30779607-vmss000000   Ready    <none>  40m   v1.34.8   ...   Ubuntu 22.04.5 LTS  5.15.0-1114-azure   containerd://1.7.32-1
aks-nodepool1-30779607-vmss000001   Ready    <none>  40m   v1.34.8   ...   Ubuntu 22.04.5 LTS  5.15.0-1114-azure   containerd://1.7.32-1
```

Three dead giveaways to point at on screen:

- **Node names** start with `aks-nodepool1-...-vmss...` — an AKS Virtual Machine Scale Set.
- **Kernel version** literally ends in **`-azure`**.
- Your **kubectl context** is the AKS cluster:

  ```bash
  kubectl config current-context   # -> radius-quickstart-aks
  ```

Then show the demo pod is scheduled onto one of those Azure nodes (look at the `NODE` column):

```bash
kubectl get pods -n demo-app -o wide
```

```
NAME                    READY   STATUS    ...   NODE
demo-75d97c9c49-cv8ds   1/1     Running   ...   aks-nodepool1-30779607-vmss000001
```

For an extra-visual finish, open the **Azure Portal → your AKS cluster → Kubernetes resources
→ Workloads** and show the same `demo` pod listed there — proof it lives in your Azure
subscription, with `localhost` merely tunneling into it.

---

## Step 5 — Clean up

To avoid ongoing Azure charges, tear everything down:

```bash
./scripts/cleanup.sh
```

This uninstalls Radius (`rad uninstall kubernetes --purge`), deletes the workload-identity
managed identity (and its federated credentials), and deletes **both** resource groups —
the one holding the AKS cluster and the one holding Radius-deployed Azure resources — each
with a confirmation prompt.

To keep all Azure resources but remove only Radius:

```bash
DELETE_AZURE=false ./scripts/cleanup.sh
```

---

## Troubleshooting

### `kubectl` tries to reach `127.0.0.1:...` / connection refused after setup

This happens on **WSL** when `az` is the **Windows** CLI (`/mnt/c/.../az`) but `kubectl`
and `rad` are **Linux** binaries. `az aks get-credentials` then writes the AKS context to
the *Windows* kubeconfig (`C:\Users\<you>\.kube\config`), while `kubectl`/`rad` read the
*Linux* one (`~/.kube/config`) — which still points at some stale local cluster (kind/k3d).

`setup-aks.sh` now detects this and **merges** the AKS context into the Linux kubeconfig
automatically. If you hit it on an older run, fix it manually:

```bash
KUBECONFIG="$HOME/.kube/config:/mnt/c/Users/<you>/.kube/config" \
  kubectl config view --flatten > "$HOME/.kube/config.merged"
mv "$HOME/.kube/config.merged" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
kubectl config use-context <your-aks-cluster-name>
kubectl get nodes   # should list the AKS nodes
```

The cleanest long-term fix is to use the **Linux** Azure CLI inside WSL so all three tools
share `~/.kube/config`.

### `az` errors when setting up the Azure provider

If you chose **Service Principal** in `rad init` and hit one of these, it's a tenant policy:

| Error | Cause | Fix |
|---|---|---|
| `ServiceManagementReference field is required` | Tenant requires every app registration to reference a Service Tree ID | Not relevant for the managed-identity path the scripts use |
| `Credential type not allowed as per assigned policy` | Tenant forbids client secrets on app registrations | Use **Workload Identity** (the scripts' default), not Service Principal |
| `FederatedIdentityCredential.Issuer ... not allowed as per assigned policy` | Tenant restricts which OIDC issuers an *app registration* may federate to | Use a **user-assigned managed identity** (the scripts do this) — it isn't subject to that policy |

`install-radius.sh` avoids all three by using a user-assigned managed identity with federated
credentials instead of a service principal.

### `az -o tsv` values contain stray characters under WSL

The Windows `az` CLI appends a carriage return (`\r`) to `-o tsv` output. Embedding such a
value in JSON (e.g. a federated-credential issuer) fails with `Invalid control character`.
The scripts pipe captured values through `tr -d '\r\n'` to avoid this.

---

## File layout

```
aks-quickstart/
├── README.md                  # this guide
├── app/
│   └── app.bicep              # the Radius "demo" container application
└── scripts/
    ├── setup-aks.sh           # provision AKS (with OIDC issuer + workload identity) + set kubectl context
    ├── install-radius.sh      # set up Azure Workload Identity, install Radius, deploy app
    └── cleanup.sh             # uninstall Radius + delete managed identity + delete resource groups
```

## References

- Radius quickstart: <https://docs.radapp.io/quick-start/>
- Radius on Kubernetes (supported clusters): <https://docs.radapp.io/guides/operations/kubernetes/overview/>
- AKS quickstart (Azure CLI): <https://learn.microsoft.com/azure/aks/learn/quick-kubernetes-deploy-cli>
