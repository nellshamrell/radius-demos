# Radius Quickstart on Amazon Elastic Kubernetes Service (EKS)

This demo walks you through deploying your first [Radius](https://radapp.io) application —
the same containerized **Todo List / demo** app from the
[official Radius quickstart](https://docs.radapp.io/quick-start/) — but instead of running on a
local Kubernetes cluster (k3d/kind), it runs on a real **EKS cluster on AWS**.

By the end you will have:

- An EKS cluster running in your AWS account
- The Radius control plane installed on that cluster
- The `demo` container application deployed and reachable via port-forwarding
- A clean teardown path so you don't keep paying for AWS resources

---

## Architecture at a glance

```
   Your workstation                       AWS
  ┌────────────────┐               ┌───────────────────────────┐
  │  rad CLI       │   kubectl     │  EKS cluster               │
  │  kubectl       │──────────────▶│   ├─ radius-system ns      │  ← Radius control plane
  │  aws / eksctl  │   (kubeconfig)│   └─ demo-app ns           │  ← your app's pods/services
  └────────────────┘               │  + VPC, managed node group │
                                   └───────────────────────────┘
```

Radius installs into the `radius-system` namespace and deploys your application's
Kubernetes objects (Deployment, Service, ServiceAccount, Role, RoleBinding) into the
cluster, exactly as it would locally — the only difference is the cluster lives in AWS.

---

## Prerequisites

You need the following installed and configured on your workstation:

| Tool | Purpose | Install |
|------|---------|---------|
| **AWS CLI** (`aws`) | Authenticate to AWS and manage IAM | <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html> |
| **eksctl** | Create and delete the EKS cluster | <https://eksctl.io/installation/> |
| **kubectl** | Talk to the cluster | <https://kubernetes.io/docs/tasks/tools/> |
| **Radius CLI** (`rad`) | Install Radius and deploy the app (the script installs this for you if missing) | <https://docs.radapp.io/installation/> |
| An **AWS account** | Hosts the EKS cluster | <https://aws.amazon.com/free/> |

Then configure your AWS credentials:

```bash
aws login              # or: aws sso login --profile <your-profile>
aws sts get-caller-identity   # verify you're authenticated
```

> **Cost note:** An EKS cluster has an hourly control-plane charge (~$0.10/hr) **plus**
> the EC2 instances in the node group. Run [`scripts/cleanup.sh`](scripts/cleanup.sh) when
> you're done to delete everything.

---

## Step 1 — Provision the EKS cluster

From the `eks-quickstart/` directory:

```bash
./scripts/setup-eks.sh
```

This script:

1. Verifies the `aws`, `eksctl`, and `kubectl` CLIs are installed.
2. Verifies your AWS credentials with `aws sts get-caller-identity`.
3. Creates an EKS cluster (`radius-quickstart-eks`, 2 nodes) with `eksctl` — Radius requires
   Kubernetes ≥ 1.23.8, which the default version satisfies.
4. Associates the cluster's **IAM OIDC provider** (required for IRSA in Step 2).
5. Runs `aws eks update-kubeconfig` to merge the cluster into your kubeconfig and set it as the
   current context.
6. Verifies connectivity with `kubectl get nodes`.

You can customize the deployment with environment variables:

```bash
AWS_REGION=us-east-1 CLUSTER_NAME=my-eks NODE_COUNT=3 NODE_TYPE=t3.xlarge ./scripts/setup-eks.sh
```

Under the hood it runs the equivalent of:

```bash
eksctl create cluster \
  --name radius-quickstart-eks --region us-west-2 \
  --node-type t3.large --nodes 2 --managed --with-oidc
eksctl utils associate-iam-oidc-provider --cluster radius-quickstart-eks --approve
aws eks update-kubeconfig --name radius-quickstart-eks --region us-west-2
```

Confirm your context points at EKS:

```bash
kubectl config current-context   # -> arn:aws:eks:us-west-2:<account>:cluster/radius-quickstart-eks
```

> **Provisioning time:** `eksctl create cluster` typically takes 15-20 minutes because it
> builds a full CloudFormation stack (VPC, subnets, security groups, managed node group).
> It is not hung — leave it running.

---

## Step 2 — Install Radius and deploy the app

```bash
./scripts/install-radius.sh
```

This script:

1. Installs the Radius CLI if `rad` isn't already on your `PATH`.
2. Confirms the target cluster (your EKS context) before proceeding.
3. **Sets up AWS IRSA** (unless `AWS_AUTH` is `accesskey` or `none`): creates an IAM role
   federated to the cluster's OIDC provider, trusted by the Radius control-plane service
   accounts, and attaches a permissions policy (see below).
4. Installs the Radius control plane onto EKS with `rad install kubernetes`.
5. Annotates the `radius-system` service accounts with the IRSA role and restarts them.
6. Creates a Radius environment with `rad init --full`.
7. Deploys [`app/app.bicep`](app/app.bicep) with `rad deploy`.
8. Prints the application graph with `rad app graph`.

### AWS provider: which credential kind?

`rad init --full` asks how Radius should authenticate to AWS — **Access Key** or **IRSA**
(IAM Roles for Service Accounts). The script sets up **IRSA** by default because it uses
**no static credentials**: the Radius control-plane pods assume an IAM role using the EKS
cluster's OIDC provider, the AWS-native equivalent of Azure Workload Identity. When prompted,
choose **IRSA** and paste the **IAM role ARN**, **region**, and **account ID** the script prints.

> **Why IRSA, not access keys?** Static access keys are long-lived secrets that must be
> stored, rotated, and can leak. IRSA issues short-lived, automatically-rotated credentials
> scoped to specific Kubernetes service accounts — the recommended pattern on EKS. The script
> creates one IAM role whose trust policy federates the Radius `applications-rp`, `bicep-de`,
> `ucp`, and `dynamic-rp` service accounts (in the `radius-system` namespace) to the cluster's
> OIDC provider.

> **This demo doesn't actually need AWS.** `app.bicep` only deploys a container — it
> provisions zero AWS resources. To skip the AWS provider entirely:
>
> ```bash
> AWS_AUTH=none ./scripts/install-radius.sh
> ```
>
> To use a static access key/secret instead of IRSA:
>
> ```bash
> AWS_AUTH=accesskey ./scripts/install-radius.sh
> ```
>
> IRSA matters once your app declares real AWS resources (S3, DynamoDB, etc.).

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

You can also confirm the underlying Kubernetes objects directly on EKS:

```bash
kubectl get deployment,service,pod -n demo-app
```

---

## Step 4 — Prove it's really running on EKS (not a local cluster)

Since you reach the app at `http://localhost:3000`, viewers may assume it's running locally —
but `localhost` is only the `rad run` **port-forward tunnel**. The container actually runs on
an EC2 instance in your EKS cluster. The quickest way to prove it (no app changes) is to show
the **nodes** the workload runs on. In a second terminal:

```bash
kubectl get nodes -o wide
```

The output is unmistakably EKS, not kind/k3d/Docker Desktop:

```
NAME                                          STATUS   ROLES   AGE   VERSION              ...   OS-IMAGE         CONTAINER-RUNTIME
ip-192-168-12-34.us-west-2.compute.internal   Ready    <none>  40m   v1.31.0-eks-...      ...   Amazon Linux 2   containerd://1.7.x
ip-192-168-56-78.us-west-2.compute.internal   Ready    <none>  40m   v1.31.0-eks-...      ...   Amazon Linux 2   containerd://1.7.x
```

Three dead giveaways to point at on screen:

- **Node names** are EC2 private DNS names like `ip-192-168-12-34.us-west-2.compute.internal`.
- **Kubernetes version** carries the `-eks-` build suffix.
- Your **kubectl context** is the EKS cluster ARN:

  ```bash
  kubectl config current-context
  # -> arn:aws:eks:us-west-2:<account>:cluster/radius-quickstart-eks
  ```

Then show the demo pod is scheduled onto one of those EC2 nodes (look at the `NODE` column):

```bash
kubectl get pods -n demo-app -o wide
```

```
NAME                    READY   STATUS    ...   NODE
demo-75d97c9c49-cv8ds   1/1     Running   ...   ip-192-168-56-78.us-west-2.compute.internal
```

For an extra-visual finish, open the **AWS Console → EKS → your cluster → Resources →
Workloads** and show the same `demo` pod listed there — proof it lives in your AWS account,
with `localhost` merely tunneling into it.

---

## Step 5 — Clean up

To avoid ongoing AWS charges, tear everything down:

```bash
./scripts/cleanup.sh
```

This uninstalls Radius (`rad uninstall kubernetes --purge`), deletes the IRSA IAM role (after
detaching its policies), and deletes the **EKS cluster** with `eksctl delete cluster` (which
also removes the VPC and node group) — each destructive step with a confirmation prompt.

To keep all AWS resources but remove only Radius:

```bash
DELETE_AWS=false ./scripts/cleanup.sh
```

---

## Troubleshooting

### `aws sts get-caller-identity` fails / credentials expired

The scripts authenticate with whatever credentials your shell has. If you use AWS SSO, refresh
them first:

```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

Make sure `AWS_REGION` (or your profile's default region) matches the region you created the
cluster in — `setup-eks.sh`, `install-radius.sh`, and `cleanup.sh` all default to `us-west-2`.

### `rad init` can't authenticate to AWS / IRSA not working

IRSA requires three things, all of which the scripts handle:

| Requirement | Set up by |
|---|---|
| The cluster's IAM OIDC provider is registered | `setup-eks.sh` (`eksctl ... --with-oidc` / `associate-iam-oidc-provider`) |
| An IAM role whose trust policy federates the `radius-system` service accounts | `install-radius.sh` |
| Each service account annotated with `eks.amazonaws.com/role-arn` | `install-radius.sh` (then restarts the deployments) |

If you installed Radius **before** the annotations were applied, re-run the annotation/restart:

```bash
ROLE_ARN=$(aws iam get-role --role-name radius-quickstart-irsa --query Role.Arn --output text)
for sa in applications-rp bicep-de ucp dynamic-rp; do
  kubectl annotate serviceaccount "$sa" -n radius-system \
    "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite
done
kubectl rollout restart deployment -n radius-system
```

### `eksctl create cluster` fails partway through

eksctl provisions via CloudFormation. A partial failure can leave stacks behind. Inspect and
delete them, then retry:

```bash
eksctl get cluster --region us-west-2
eksctl delete cluster --name radius-quickstart-eks --region us-west-2 --wait
```

### IAM role won't delete

A role must have all attached managed policies **detached** before deletion. `cleanup.sh` does
this automatically; if you delete manually, detach `PowerUserAccess` (or whatever
`ROLE_POLICY_ARN` you used) first.

---

## File layout

```
eks-quickstart/
├── README.md                  # this guide
├── app/
│   ├── app.bicep              # the Radius "demo" container application
│   ├── bicepconfig.json       # radius + aws Bicep extensions
│   └── .rad/rad.yaml          # workspace config
└── scripts/
    ├── setup-eks.sh           # provision EKS (with IAM OIDC provider) + set kubectl context
    ├── install-radius.sh      # set up AWS IRSA, install Radius, deploy app
    └── cleanup.sh             # uninstall Radius + delete IAM role + delete EKS cluster
```

## References

- Radius quickstart: <https://docs.radapp.io/quick-start/>
- Radius on Kubernetes (supported clusters): <https://docs.radapp.io/guides/operations/kubernetes/overview/>
- EKS getting started (eksctl): <https://docs.aws.amazon.com/eks/latest/userguide/getting-started-eksctl.html>
- IAM Roles for Service Accounts (IRSA): <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
