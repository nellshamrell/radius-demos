# Radius Tutorial Screencast Script

A screencast walkthrough of the [official Radius tutorial](https://docs.radapp.io/tutorials/),
running on a real **Azure Kubernetes Service (AKS)** cluster. Aimed at developers who are
**brand new to Radius**.

- **Estimated runtime:** ~20–25 minutes on screen (the cluster provisioning is done *before*
  recording).
- **Format:** `[NARRATION]` = what you say to camera / voiceover. `[SCREEN]` = what you do or
  type on screen. `[TYPE]` = exact command to run.
- **Terminals:** Keep two terminals handy — **T1** for the main flow, **T2** for the dashboard
  port-forward.

---

## Pre-demo setup (do this BEFORE you hit record)

> These steps provision the AKS cluster and can take 10–15 minutes, so complete them off-camera.
> Guidance adapted from the sibling [`aks-quickstart/`](../aks-quickstart/) demo.

### 0.1 — Tools

Confirm these are installed and on your `PATH`:

| Tool | Purpose |
|------|---------|
| Azure CLI (`az`) | Create/manage the AKS cluster |
| `kubectl` | Talk to the cluster |
| Node.js | Required by the Radius CLI install step |
| Radius CLI (`rad`) | Installed on camera in Part 1 |

### 0.2 — Log in to Azure

```bash
az login
az account set --subscription "<your-subscription-id-or-name>"
```

### 0.3 — Provision the AKS cluster

The quickest path is the helper script from the sibling demo:

```bash
cd ../aks-quickstart
./scripts/setup-aks.sh
```

This creates a resource group (`radius-quickstart-rg`), an AKS cluster
(`radius-quickstart-aks`, 2 × `Standard_DS2_v2` nodes), merges the kubeconfig, and sets it as
your current `kubectl` context. It also auto-falls-back to a usable region if your subscription
restricts VM sizes.

> **Note:** This tutorial's PostgreSQL Recipe deploys **into Kubernetes**, so it provisions **no
> Azure resources**. You do **not** need Azure Workload Identity for this demo — the plain AKS
> cluster is enough. (Do **not** run `install-radius.sh`; we install Radius on camera using the
> tutorial's own `rad install kubernetes` flow.)

The equivalent raw commands, if you prefer to run them by hand:

```bash
az group create --name radius-quickstart-rg --location eastus2
az aks create --resource-group radius-quickstart-rg --name radius-quickstart-aks \
  --node-count 2 --node-vm-size Standard_DS2_v2 --generate-ssh-keys
az aks get-credentials --resource-group radius-quickstart-rg --name radius-quickstart-aks
```

### 0.4 — Silence Azure Policy admission warnings (recommended for a clean recording)

If your subscription has an **Azure Policy** assignment that governs AKS, the cluster may come up
with the **Azure Policy add-on** (Gatekeeper) enabled — even though `setup-aks.sh` never asks for
it. When it's on, `rad install kubernetes` prints a wall of warnings like:

```
Warning: [azurepolicy-k8sazurev2customcontainerallow-...] Container image
ghcr.io/radius-project/dashboard:0.59 for container dashboard has not been allowed.
```

These are **harmless**: the constraint runs in `warn` mode (not `deny`), so nothing is blocked —
every Radius pod still installs and runs. They come from an "allowed container images" policy whose
registry allowlist doesn't include `ghcr.io/radius-project/*`. But they clutter the screen, so
disable the add-on before recording:

```bash
az aks disable-addons --addons azure-policy \
  -g radius-quickstart-rg -n radius-quickstart-aks
```

> **Caveat:** If a `DeployIfNotExists` policy governs the subscription, Azure may silently
> re-enable the add-on later. Re-check right before you record:
> ```bash
> az aks show -g radius-quickstart-rg -n radius-quickstart-aks \
>   --query "addonProfiles.azurepolicy.enabled" -o tsv   # want: false
> ```
> If it keeps coming back, just filter the output instead:
> `rad install kubernetes 2>&1 | grep -v azurepolicy`

### 0.5 — Confirm you're pointed at AKS

```bash
kubectl config current-context   # -> radius-quickstart-aks
kubectl get nodes                # -> aks-nodepool1-...-vmss... nodes, Ready
```

### 0.6 — Pre-record checklist

- [ ] `kubectl get nodes` shows AKS nodes as `Ready`.
- [ ] Azure Policy add-on is **disabled** (`az aks show ... --query addonProfiles.azurepolicy.enabled` → `false`), or you're filtering the `rad install` output.
- [ ] `radius-system` namespace does **not** exist yet (`kubectl get ns` — we install Radius live).
- [ ] Working directory is clean (e.g. `~/radius-tutorial`) with two terminals open.
- [ ] Browser open, ready to hit `http://localhost:7007` and `http://localhost:3000`.
- [ ] Font size bumped up for readability.

---

## ON-CAMERA SCRIPT

### Intro (~1 min)

**[NARRATION]**
> "Hello there! In this video, we're going to deploy a 
> cloud-native application to a Kubernetes cluster using Radius. Radius is an open-source platform that lets developers
> describe a whole application, its containers, its databases, and the connections between them,
> as a single, self-contained model. Platform engineers define *how* infrastructure gets created,
> so application developers can just say *what* they need when they need it. We'll run everything on a real AKS cluster in Azure.
> Let's dive in."

**[SCREEN]** Show the AKS cluster is real and ready:

> "Let's start by taking a look at this AKS cluster."

**[TYPE]** (T1)
```bash
kubectl get nodes -o wide
```

**[NARRATION]**
> "Notice the node names start with `aks-nodepool1` and the kernel version ends in `-azure` —
> this is a genuine AKS cluster running in the Azure cloud.

---

### Part 1 — Install Radius (~3 min)

**[NARRATION]**
> "In order to use Radius on this cluster, we first need to install it. Let's go ahead and do that now."

**[TYPE]** (T1):
```bash
rad install kubernetes
kubectl get pods -n radius-system
```

> **If you skipped step 0.4** and see `azurepolicy-...has not been allowed` warnings, they're
> harmless (Azure Policy add-on in `warn` mode) — the install still succeeds. Disable the add-on
> or pipe through `grep -v azurepolicy` for a clean recording.

**[SCREEN]** Wait for all pods `Running`: `applications-rp`, `bicep-de`, `controller`,
`dashboard`, `dynamic-rp`, `ucp`.

**[NARRATION]**
> "Radius installs into its own `radius-system` namespace on Kubernetes. These pods are the Radius control
> plane — the brain that will manage our resource types, recipes, environments, and applications
> on this cluster."

---

### Part 2 — Create a Resource Type (~4 min)

**[NARRATION] — concept: Resource Types (3–5 sentences)**
> "The first Radius concept to understand is a **Resource Type**. A Resource Type defines *what* a developer is
> allowed to deploy — think of it as a custom, reusable API for a piece of infrastructure, like a
> database or a message queue. It's described with an OpenAPI schema that lists the properties a
> developer can set, like a database `size`, and the read-only outputs they'll get back, like a
> `host` and `password`. Platform teams create these types once so developers get a clean,
> consistent interface instead of raw YAML. Let's take a look at a `postgreSqlDatabases` Resource Type."

**[SCREEN]** Download / open the type definition file, and walk through it briefly.

**[TYPE]** (T1) — grab the tutorial's definition file:
```bash
curl -fsSLO https://docs.radapp.io/tutorials/create-resource-type/postgreSqlDatabases.yaml
```

**[SCREEN]** Open `postgreSqlDatabases.yaml`, point out: `namespace: Radius.Data`, the `types`
name, `apiVersions`, and the `schema` — highlighting the writable `size` property and the
read-only `host`, `port`, `username`, `password` outputs.

Now that we have this type defined in this file, let's register it with our Radius cluster.

**[TYPE]** (T1) — register the type:
```bash
rad resource-type create postgreSqlDatabases -f postgreSqlDatabases.yaml
```

**[NARRATION]**
> "Radius now knows about our `postgreSqlDatabases` type. Next we generate a Bicep extension so
> our infrastructure-as-code files — and VS Code — get autocomplete and validation for this type when we or our developers use it."

**[TYPE]** (T1):
```bash
rad bicep publish-extension -f postgreSqlDatabases.yaml --target radiusResources.tgz
```

> "Now, let's create a bicepconfig file so that we are able to use this extension


**[SCREEN]** Create `bicepconfig.json`:
```json
{
    "extensions": {
        "radius": "br:biceptypes.azurecr.io/radius:latest",
        "radiusResources": "radiusResources.tgz"
    }
}
```

**[NARRATION] — why this file?**
> "So why do we need this file? Bicep is a typed language, so before it can compile our app it has
> to know the *shape* of every resource type we use — its properties and which are required. Those
> definitions come from **Bicep extensions**, and `bicepconfig.json` is what tells Bicep which
> extensions to load and where to find them. The `radius` entry pulls the built-in Radius types
> like containers and applications from a public registry, and the `radiusResources` entry points
> at the `.tgz` we just published — that's what teaches Bicep about our custom
> `postgreSqlDatabases` type. Notice this is a separate step from `rad resource-type create`: that
> command taught the Radius *control plane* about the type, and this file teaches the Bicep
> *compiler* about it — both sides need to know."

**[NARRATION] — concept: Radius Dashboard**
> "Radius ships with a **Dashboard** — a web GUI for browsing your resource types, environments,
> and applications. Let's port-forward to it and see our new type, including the documentation we
> wrote right in the schema."

**[TYPE]** (T2 — leave running):
```bash
kubectl port-forward --namespace=radius-system svc/dashboard 7007:80
```

**[SCREEN]** Open `http://localhost:7007/resource-types/Radius.Data/postgreSqlDatabases` and show
the auto-generated documentation page.

Now let's move onto a related Radius concept - recipes.

---

### Part 3 — Understand the Recipe (~3 min)

**[NARRATION] — concept: Recipes (3–5 sentences)**
> "A Resource Type says *what* can be deployed; a **Recipe** says *how* it actually gets created.
> A Recipe is an infrastructure-as-code template — Bicep or Terraform — that a platform engineer
> defines to provision the real thing behind a Resource Type. When a developer asks for a
> `postgreSqlDatabases`, Radius runs the Recipe to stand up an actual PostgreSQL instance.

Let's take a look at an example

**[SCREEN]** Show the Recipe source
([kubernetes-postgresql.bicep](https://github.com/radius-project/docs/tree/v0.56/docs/content/tutorials/create-recipe/recipes/bicep/kubernetes-postgresql.bicep))
and point at:
1. The injected **`context`** parameter — carries the resource's and environment's properties
   (e.g. `context.resource.properties.size`).
2. A **`memory` variable** that maps the developer's `size` (S/M/L) to a container memory request.
3. The required **`result` output** — how the Recipe returns `host`, `port`, `database`,
   `username`, `password` back to Radius as the type's read-only outputs.

**[NARRATION] — concept: Recipes live in an OCI registry (3–5 sentences)**
> "One more thing about Recipes: unlike a resource type, a Recipe doesn't live inside the Radius control plane — it lives
> in an **OCI registry**, the same kind of registry that stores container images, like GitHub
> Container Registry or Azure Container Registry. Radius stores it there because the control-plane
> components running in your cluster need to **pull** the Recipe template at deploy time, and a
> registry is a versioned, shareable place any environment reference by its registry path.

**[NARRATION]**
> "For this tutorial, we have **already published**
> this PostgreSQL Recipe a public registry on GitHub Container Registry, so we'll skip this step.

### Part 4 — Create an Environment (~4 min)

Next, let's talk about environments.

**[NARRATION] — concept: Groups, Environments, Workspaces (3–5 sentences)**
> "Now we assemble the deployment target. Everything in Radius lives inside a **Resource Group** —
> a logical container for your resources. An **Environment** defines *where* resources deploy and
> *which* Recipes to use — so you can have `dev`, `staging`, and `prod` environments that each map
> the same Resource Type to different Recipes. And a **Workspace** is just local CLI configuration
> that ties together your `kubectl` context, an Environment, and a Resource Group so `rad` knows
> where to send things. Let's create all three."

**[TYPE]** (T1):
```bash
rad group create my-group
rad environment create my-env --group my-group
rad environment show my-env --group my-group --output json
```

**[NARRATION]**
> "Notice the environment's compute is `kubernetes` — it'll deploy into a namespace on our AKS
> cluster."

> Next, let's define a workspace - a **Workspace** is just local CLI configuration
> that ties together your `kubectl` context, an Environment, and a Resource Group so the rad cli knows
> where to send things. Let's create one now:

**[TYPE]** (T1) — workspace:
```bash
rad workspace create kubernetes my-workspace \
  --context $(kubectl config current-context) \
  --environment my-env \
  --group my-group
rad workspace show --output json
```

**[NARRATION]**
> "Finally, the key step that connects everything: we **register the Recipe** into the environment
> for our Resource Type. 

**[TYPE]** (T1):
```bash
rad recipe register default \
  --environment my-env \
  --resource-type Radius.Data/postgreSqlDatabases \
  --template-kind bicep \
  --template-path ghcr.io/radius-project/recipes/kubernetes/postgresql:0.53.0

rad recipe list --environment my-env
```

From now on, any request for a `postgreSqlDatabases` in `my-env` runs this recipe.

---

### Part 5 — Deploy the Application (~4 min)

**[NARRATION] — concept: Applications (3–5 sentences)**
> "And the last piece is the **Application** — the thing developers actually author. An Application is a
> single model that describes all the resources your app is made of and, crucially, the
> **connections** between them. We'll define an app with a `frontend` container connected
> to a `postgresql` database of our new Resource Type. 


**[SCREEN]** Create `app.bicep`:
```bicep
extension radius
extension radiusResources

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource todolist 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'todolist'
  properties: {
    environment: environment
  }
}

resource postgresql 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: todolist.id
    size: 'S'
  }
}

resource frontend 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'frontend'
  properties: {
    application: todolist.id
    container: {
      image: 'ghcr.io/radius-project/samples/demo:latest'
      ports: {
        web: {
          containerPort: 3000
        }
      }
    }
    connections: {
      postgresql: {
        source: postgresql.id
      }
    }
  }
}
```

**[SCREEN]** Point out the three resources and the `connections` block linking `frontend` →
`postgresql`

> "Because we declare a connection, Radius
> automatically injects the database's connection details into the container as environment
> variables — you don't have to manually wire it up.

Now that we've got everything set up, let's go ahead and deploy.

**[TYPE]** (T1) — deploy:
```bash
rad deploy app.bicep
```

**[SCREEN]** Watch the deployment progress: `todolist`, `postgresql`, `frontend` all `Completed`.

**[NARRATION]**
> "In one command Radius ran our Recipe to create the Postgres database, deployed the container,
> and wired the connection between them. Let's see it."

**[TYPE]** (T1) — expose the app:
```bash
rad resource expose Applications.Core/containers frontend -a todolist --port 3000
```

We're exposing the application on port 3000 of our localhost.

**[NARRATION] — why localhost and not a public URL? (3–5 sentences)**
> "You might be wondering why we're opening things up on `localhost` when this app is running on aks on Azure. It's
> because our container only listens on an **internal** port inside the cluster — we never gave it
> a public load balancer or ingress, so there's no external IP to browse to. `rad resource expose`
> sets up a **port-forward**: a secure tunnel from a port on my laptop straight to the container's
> port on the cluster, over the Kubernetes API. So `localhost:3000` is just the near end of that
> tunnel — every request is actually being served by the pod on an Azure node. This is the quick,
> safe way to reach an internal service for a demo without exposing it to the whole internet; If you ran this in
> production you'd add a Radius **Gateway** to give it a real public route."

**[SCREEN]** Open `http://localhost:3000` — show the working Todo List app; add a couple of todos
to prove the database connection works.

**[NARRATION]**
> "And there's our app — the todos you add are being persisted to the PostgreSQL database that
> Radius provisioned for us."

---

### Show the graph in the Dashboard (~1 min)

**[SCREEN]** In the browser (dashboard already forwarded on T2), open
`http://localhost:7007/resources/my-group/Applications.Core/applications/todolist/application`.

**[NARRATION]**
> "The Dashboard visualizes the whole application graph — the `frontend` container, the
> `postgresql` database, and the connection between them. This graph *is* your application model,
> and it's running on real infrastructure in AKS."

### Wrap-up & Cleanup (~1 min)

**[NARRATION]**
> "So that's Radius end to end. We defined a **Resource Type** as a developer-facing API, a
> **Recipe** to implement it, an **Environment** that ties recipes to a deployment target, and an
> **Application** that models our containers and databases with the connections between them —
> then deployed the whole thing to AKS with one command. Thanks for watching!"

**[SCREEN]** Cleanup (can be off-camera):

**[TYPE]** (T1) — remove the app and, optionally, Radius:
```bash
rad application delete todolist
rad uninstall kubernetes --purge      # optional
```

**[TYPE]** — tear down the AKS cluster to stop Azure charges:
```bash
cd ../aks-quickstart
./scripts/cleanup.sh
# or, manually:
# az group delete --name radius-quickstart-rg --yes --no-wait
```

---

## Appendix — Command cheat-sheet (in order)

```bash
# Pre-demo (off camera)
az login
cd ../aks-quickstart && ./scripts/setup-aks.sh && cd -
kubectl get nodes

# Part 1 — install Radius
curl -fsSL "https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh" | /bin/bash
rad install kubernetes
kubectl get pods -n radius-system

# Part 2 — resource type
curl -fsSLO https://docs.radapp.io/tutorials/create-resource-type/postgreSqlDatabases.yaml
rad resource-type create postgreSqlDatabases -f postgreSqlDatabases.yaml
rad bicep publish-extension -f postgreSqlDatabases.yaml --target radiusResources.tgz
# create bicepconfig.json
kubectl port-forward --namespace=radius-system svc/dashboard 7007:80   # terminal 2

# Part 4 — environment
rad group create my-group
rad environment create my-env --group my-group
rad workspace create kubernetes my-workspace \
  --context $(kubectl config current-context) --environment my-env --group my-group
rad recipe register default --environment my-env \
  --resource-type Radius.Data/postgreSqlDatabases \
  --template-kind bicep \
  --template-path ghcr.io/radius-project/recipes/kubernetes/postgresql:0.53.0

# Part 5 — deploy
# create app.bicep
rad deploy app.bicep
rad resource expose Applications.Core/containers frontend -a todolist --port 3000

# Cleanup
rad application delete todolist
cd ../aks-quickstart && ./scripts/cleanup.sh
```
