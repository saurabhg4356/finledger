# FinLedger — Phase 4: Infrastructure as Code

Terraform for: VPC (1 NAT gateway, 2 AZs), EKS Fargate cluster, RDS Postgres (Multi-AZ toggleable), ElastiCache Redis, and 3 ECR repositories.

## Before you run this

**I could not run `terraform init`/`validate`/`plan` in my sandbox** — no network access to the Terraform registry. I hand-checked every file for syntax (brace balance, HCL structure) but you should run `terraform validate` yourself before `plan`, and read `terraform plan` output carefully before `apply`. This is real AWS spend.

**Confirm Phase 0 guardrails are already applied** in this account before running this. If they aren't, stop and go back — this phase is where actual cost starts accumulating.

## Estimated cost (ap-south-1, `rds_multi_az = false`, `db.t4g.micro`, `cache.t4g.micro`)

Roughly $50–70/month if left running 24/7 — EKS control plane ($0.10/hr ≈ $73/mo alone is usually the largest single line item, followed by the NAT Gateway. RDS and ElastiCache at these instance sizes are comparatively small. **This is exactly why Phase 0's nightly stop/start exists for RDS, and why you should `terraform destroy` this stack between study sessions rather than leaving it running.** EKS control plane and NAT Gateway have no stop/start option — destroying and recreating them is the only lever.

## Steps

### 1. Push images to ECR first (needs the repos to exist)
```bash
cd terraform
terraform init
terraform apply -target=module.ecr
```
This creates just the 3 ECR repos without touching networking/EKS/RDS yet — lets you validate the ECR piece cheaply and independently.

```bash
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-south-1.amazonaws.com

# repeat for each service
docker build -t finledger-account-service ../phase2-core-services/services/account-service
docker tag finledger-account-service:latest <account-id>.dkr.ecr.ap-south-1.amazonaws.com/finledger-account-service:v1
docker push <account-id>.dkr.ecr.ap-south-1.amazonaws.com/finledger-account-service:v1
```

### 2. Apply the rest
```bash
terraform apply
```
Review the plan first — expect roughly: 1 VPC, 4 subnets, 1 NAT gateway, 1 EKS cluster, 2 Fargate profiles, 1 RDS instance, 1 ElastiCache node, 3 ECR repos (already applied), plus supporting IAM roles/security groups.

### 3. Connect kubectl
```bash
aws eks update-kubeconfig --name finledger-cluster --region ap-south-1
kubectl get nodes   # expect: no nodes listed — this is CORRECT on Fargate, pods run without visible "nodes"
```

### 4. Patch CoreDNS to run on Fargate
This is the exact issue from your ShopSphere blog post — CoreDNS's default deployment doesn't target Fargate, so it stays `Pending` until patched:
```bash
kubectl patch deployment coredns \
  -n kube-system \
  --type json \
  -p '[{"op": "remove", "path": "/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]'

kubectl rollout status deployment coredns -n kube-system
```

### 5. Create the app namespace
```bash
kubectl create namespace finledger
```
(The `finledger` Fargate profile from Terraform only takes effect for pods scheduled into this namespace — nothing will schedule correctly without it.)

### 6. Verify RDS and Redis are reachable
Credentials are in Secrets Manager, not in Terraform state as plaintext beyond what's needed:
```bash
terraform output rds_secret_arn
aws secretsmanager get-secret-value --secret-id <arn-from-above> --query SecretString --output text
```
Full app deployment (Kubernetes manifests, ESO wiring the above secret into pods) is Phase 5 — this phase just proves the infrastructure itself exists and is reachable.

## Cost optimization notes — corrections to the original Phase 2 roadmap

Two items from the original roadmap ("Apply Fargate Spot / Graviton where safe") don't actually apply to this architecture, and it's worth knowing why rather than silently dropping them:

- **Fargate Spot does not exist for EKS.** It's an ECS-only capacity provider. On EKS, Fargate pods always run On-Demand — there's no Spot toggle available, regardless of how the Fargate profile is configured.
- **Graviton/ARM is also EKS-Fargate-unsupported.** AWS's own guidance is to use EC2 node groups if you want ARM workloads on EKS. The Lambda functions in Phase 0 *do* use Graviton (`architectures = ["arm64"]`) — that's a separate, valid use of Graviton on Lambda, not on EKS Fargate. Don't confuse the two.

The real, available cost levers for EKS Fargate specifically are: right-sizing each pod's CPU/memory requests against actual usage (Phase 10), and a Compute Savings Plan if the workload runs predictably 24/7 (up to ~50% off, no interruption risk — unlike Spot). If ARM/Graviton compute genuinely matters for your interview story, the honest way to get it here would be to add an EC2-based managed node group running Graviton instances alongside the Fargate profiles — a real architectural choice worth naming explicitly rather than pretending Fargate does something it doesn't.

## Where's the ALB?

Not provisioned directly in this Terraform. The public/private subnets are tagged (`kubernetes.io/role/elb` / `internal-elb`) so the **AWS Load Balancer Controller** — installed as a Helm chart against the cluster in Phase 5 — can auto-discover them and provision an ALB dynamically whenever a Kubernetes `Ingress` resource is created. This is the standard EKS pattern: Terraform prepares the cluster and network to support an ALB, but the ALB itself is created and destroyed by Kubernetes as workloads come and go, not hardcoded in Terraform. If you'd rather have Terraform own the ALB directly (a static ALB in front of a NodePort/target group), that's a valid alternative — just a different trade-off (simpler mental model, less dynamic) — say so and I'll add it here instead.

## Tear down between sessions
```bash
terraform destroy
```
Confirm ECR repos you want to keep aren't destroyed along with everything else. Terraform doesn't have an "exclude" flag, so to tear down everything except ECR, target each module explicitly instead:
```bash
terraform destroy \
  -target=module.eks \
  -target=module.rds \
  -target=module.elasticache \
  -target=module.networking
```
This leaves `module.ecr` untouched. Simpler alternative: just let ECR get destroyed too and re-push images next session — ECR storage cost at this scale is a few cents a month, so this is only worth the extra command if you specifically want to skip re-pushing images.