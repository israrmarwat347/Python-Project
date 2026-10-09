# Zero-cost local mode

Everything in this project runs on your laptop with Docker — **$0, no AWS**.

### Prereqs (all free, install once)

```bash
# macOS
brew install docker kind kubectl helm
# Linux (Debian/Ubuntu)
sudo apt-get install -y docker.io
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64 && \
  chmod +x kind && sudo mv kind /usr/local/bin/
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Bring up the full stack

```bash
./local/setup-local.sh
```

That script:
1. Creates a **kind** cluster (2 nodes, k8s in Docker) with host port forwards.
2. Builds the notes-app image and loads it into the cluster.
3. Deploys **Postgres + notes-app** (same manifests as the AWS path).
4. Deploys **MinIO** as a free S3-compatible artifact store.
5. Deploys **Jenkins** inside the cluster (reachable on `localhost:8080`).
6. Installs **kube-prometheus-stack** with the ServiceMonitor, the 3 alert rules, and
   the Grafana dashboard that are already in `monitoring/`.
7. Smoke-tests `/health`.

### URLs

| What | URL | Credentials |
|---|---|---|
| Notes app | http://localhost:30080 | — |
| Jenkins | http://localhost:8080 | setup wizard |
| Grafana | http://localhost:30030 | `admin` / `admin_local_dev` |
| Prometheus | http://localhost:30090 | — |
| MinIO console | http://localhost:9001 | `minioadmin` / `minioadmin123` |

### Tear it all down

```bash
./local/teardown-local.sh
```

### Still want to practice Terraform without paying?

Use **LocalStack** (AWS emulator) as the Terraform target:

```bash
docker compose -f local/localstack-compose.yml up -d
cp local/provider_override.tf terraform/provider_override.tf     # redirect to LocalStack
cd terraform
terraform init
terraform apply -var-file=../local/localstack.tfvars              # free, no AWS bill
terraform destroy -var-file=../local/localstack.tfvars
rm provider_override.tf                                           # when done practicing
```

LocalStack only emulates most AWS APIs — EC2 instances won't actually boot, but you
practice **the Terraform workflow itself** for free: `plan`, `apply`, state, outputs,
destroy, drift.

### What you give up vs the AWS path

- Real EC2 provisioning (LocalStack fakes it).
- Multi-node network isolation (kind is one Docker network).
- Ansible on remote hosts (your laptop IS the host — you can still run the playbooks
  against a local Vagrant/Multipass VM if you want).

Everything else — Docker, k8s manifests, Postgres with PVC, Prometheus scraping,
Grafana dashboard, alerts, Jenkinsfile stages — is **identical**.
