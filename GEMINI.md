# Currency Conversion Service — AI Agent Context

## Agent identity

You are a DevOps AI agent. Your job is to provision AWS infrastructure and
deploy a Spring Boot microservice to Kubernetes using the files in this repo.
You have full shell access. Execute commands directly — do not just suggest them.

> **Note for operator:** launch with `gemini -m gemini-2.5-flash-lite`

---

## Project snapshot

- **Application** — Spring Boot microservice, Java 11, port 8080
- **Docker build** — Multi-stage: Maven → `openjdk:11-jre-slim`
- **Container registry** — AWS ECR
- **Infrastructure** — AWS EKS provisioned by Terraform
- **Kubernetes namespace** — `production`
- **Health endpoint** — `GET /actuator/health` → `{"status":"UP"}`

---

## Repository layout

```
.
├── GEMINI.md                   ← agent context (this file)
├── Dockerfile                  ← multi-stage Maven build
├── terraform/
│   ├── main.tf                 ← VPC, subnets, NAT, EKS, ECR, IAM roles
│   ├── variables.tf            ← all input variables with defaults
│   ├── versions.tf             ← AWS provider + S3 backend (pre-configured)
│   ├── outputs.tf              ← ecr_repository_url, configure_kubectl, etc.
│   └── terraform.tfvars        ← actual values for this deployment
├── k8s/
│   ├── namespace.yml           ← namespace: production
│   ├── configmap.yml           ← LOG_LEVEL, SERVER_PORT, env vars
│   ├── deployment.yml          ← 3 replicas, rolling update, liveness/readiness probes
│   ├── service.yml             ← LoadBalancer, port 80 → 8080
│   ├── hpa.yml                 ← scale 2–10 pods at CPU 70% / memory 80%
│   └── pdb.yml                 ← PodDisruptionBudget minAvailable: 1
└── scripts/
    ├── gemini_deploy.sh        ← full deploy entry point
    └── gemini_validate.sh      ← post-deploy health check
```

---

## AWS values

- **Region** — `us-east-1`
- **EKS cluster** — `currency-cluster`
- **ECR repository** — `currency-conversion-service`
- **Kubernetes version** — `1.28`
- **Node type** — `t3.small`, SPOT capacity
- **Terraform S3 backend** — `tech-talk-tf-state-bucket`
- **State key** — `eks/terraform.tfstate`

Derive the ECR registry URL at runtime — run this before any step that references `$ECR_REGISTRY`:
```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
```

---

## Deployment procedure

Execute these steps in order. Do not skip or reorder them.

### 1 — Provision infrastructure

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
cd ..
```

EKS cluster creation takes ~15 minutes. Wait for `apply` to complete before continuing.

### 2 — Connect kubectl to the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name currency-cluster
kubectl get nodes   # wait until at least 1 node is Ready
```

### 3 — Build and push Docker image

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
IMAGE_TAG=$(git rev-parse --short HEAD)
FULL_IMAGE="${ECR_REGISTRY}/currency-conversion-service:${IMAGE_TAG}"

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker build -t "${FULL_IMAGE}" -t "${ECR_REGISTRY}/currency-conversion-service:latest" .

docker push "${FULL_IMAGE}"
docker push "${ECR_REGISTRY}/currency-conversion-service:latest"
```

First build takes 3–5 minutes (Maven downloads dependencies into layer cache).

### 4 — Deploy to Kubernetes

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
IMAGE_TAG=$(git rev-parse --short HEAD)
FULL_IMAGE="${ECR_REGISTRY}/currency-conversion-service:${IMAGE_TAG}"

# Namespace must come first
kubectl apply -f k8s/namespace.yml

# ConfigMap
kubectl apply -f k8s/configmap.yml -n production

# ECR pull secret — pods need this to pull images
kubectl create secret docker-registry ecr-secret \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)" \
  --namespace=production \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply manifests — deployment.yml image is updated via kubectl set image below
kubectl apply -f k8s/service.yml    -n production
kubectl apply -f k8s/deployment.yml -n production
kubectl apply -f k8s/hpa.yml        -n production
kubectl apply -f k8s/pdb.yml        -n production

# Set the correct image — works on first deploy and every subsequent one
# Container name "currency-conversion" matches spec.containers[0].name in deployment.yml
kubectl set image deployment/currency-conversion-service \
  currency-conversion="${FULL_IMAGE}" \
  -n production
```

### 5 — Wait for rollout

```bash
kubectl rollout status deployment/currency-conversion-service \
  -n production --timeout=5m
```

### 6 — Validate

```bash
kubectl get pods,svc,hpa -n production -o wide

EXTERNAL_IP=$(kubectl get svc currency-conversion-service \
  -n production \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s "http://${EXTERNAL_IP}/actuator/health"
# Expected: {"status":"UP"}
```

AWS takes 2–3 minutes to provision the ALB after the service is created.
If `EXTERNAL_IP` is empty, wait and retry.

---

## Healthy deployment state

```
NAME                                        READY   STATUS    RESTARTS
currency-conversion-service-aaa-xxx         1/1     Running   0
currency-conversion-service-aaa-yyy         1/1     Running   0
currency-conversion-service-aaa-zzz         1/1     Running   0

NAME                          TYPE           EXTERNAL-IP
currency-conversion-service   LoadBalancer   abc.elb.amazonaws.com

NAME                      TARGETS           MINPODS   MAXPODS
currency-conversion-hpa   18%/70%, 32%/80%  2         10
```

---

## Failure reference

- `ImagePullBackOff` — ECR pull secret missing or expired → re-run the `create secret` command in Step 4
- `CrashLoopBackOff` — app fails to start → `kubectl logs -n production <pod> --previous`
- `Pending` pods — nodes have insufficient CPU/memory → `kubectl describe pod -n production <pod>`
- No `EXTERNAL-IP` — AWS still provisioning ALB → wait 2–3 min, run `kubectl get svc -n production -w`
- `OOMKilled` — JVM exceeds container memory limit → confirm node type is `t3.small` not `t3.micro`
- Terraform backend error — S3 bucket does not exist → `aws s3 mb s3://tech-talk-tf-state-bucket --region us-east-1`

---

## Diagnostic commands

```bash
# All resources in namespace
kubectl get all -n production

# Recent events — scheduling failures, probe errors
kubectl get events -n production --sort-by='.lastTimestamp' | tail -20

# Live logs
kubectl logs -n production deployment/currency-conversion-service --tail=50

# Logs from crashed previous container
kubectl logs -n production <pod-name> --previous

# Pod scheduling and probe detail
kubectl describe pod -n production <pod-name>

# HPA current metrics
kubectl describe hpa -n production currency-conversion-hpa

# Node resource usage
kubectl describe nodes | grep -A5 "Allocated resources"
```

---

## Cleanup

Run after the demo to stop AWS charges (~$0.20/hour while running):

```bash
kubectl delete namespace production
cd terraform && terraform destroy -auto-approve
```

---

## Hard constraints

- Do not modify `terraform/versions.tf` — S3 backend is pre-configured
- Apply `k8s/namespace.yml` before all other manifests — others will 404 without it
- Do not change the namespace name — all manifests reference `production` by name