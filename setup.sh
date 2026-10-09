#!/usr/bin/env bash
# ================================================================
# DevOps Notes App — one-shot bootstrapper.
# Creates every file + folder, inits git, commits, pushes to main.
# Edit REMOTE_URL below if you want to push somewhere else.
# ================================================================
set -euo pipefail

REMOTE_URL="${REMOTE_URL:-https://github.com/israrmarwat347/Python-Project.git}"
PROJECT_DIR="${PROJECT_DIR:-devops-notes-app}"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

write() {
  # write <path>  —  reads heredoc from stdin and writes it to <path>
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}


# ---- .gitignore ----
write ".gitignore" <<'E_O_F_a084b794'
# Secrets & env
.env
*.env
!*.env.example

# Terraform
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.terraform/
.terraform.lock.hcl
crash.log

# SSH keys
*.pem
*.key
id_rsa*

# Python
__pycache__/
*.pyc
.pytest_cache/
.venv/
venv/

# OS/editor
.DS_Store
.idea/
.vscode/

# Ansible
*.retry

# Build artifacts
dist/
build/
*.egg-info/

E_O_F_a084b794

# ---- Dockerfile ----
write "Dockerfile" <<'E_O_F_3254677a'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /code

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt /code/requirements.txt
RUN pip install --no-cache-dir -r /code/requirements.txt

COPY app /code/app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

E_O_F_3254677a

# ---- Jenkinsfile ----
write "Jenkinsfile" <<'E_O_F_58231b16'
pipeline {
  agent any

  environment {
    DOCKERHUB_USER = 'YOUR_DOCKERHUB_USER'      // <-- replace
    IMAGE_NAME     = "${DOCKERHUB_USER}/notes-app"
    IMAGE_TAG      = "${env.BUILD_NUMBER}"
    AWS_REGION     = 'us-east-1'
    S3_BUCKET      = credentials('s3-artifacts-bucket')  // Jenkins "Secret text"
    KUBE_NAMESPACE = 'notes'
  }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Unit tests') {
      steps {
        sh '''
          python3 -m venv .venv
          . .venv/bin/activate
          pip install --upgrade pip
          pip install -r app/requirements.txt
          PYTHONPATH=. pytest -v --junitxml=test-report.xml app/tests
        '''
      }
      post {
        always { junit allowEmptyResults: true, testResults: 'test-report.xml' }
      }
    }

    stage('Build image') {
      steps {
        sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest .'
      }
    }

    stage('Push image') {
      steps {
        withCredentials([usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'DH_USER',
            passwordVariable: 'DH_PASS')]) {
          sh '''
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
            docker push ${IMAGE_NAME}:${IMAGE_TAG}
            docker push ${IMAGE_NAME}:latest
            docker logout
          '''
        }
      }
    }

    stage('Upload build report to S3') {
      steps {
        withAWS(region: "${AWS_REGION}", credentials: 'aws-creds') {
          sh '''
            echo "Build ${BUILD_NUMBER} image ${IMAGE_NAME}:${IMAGE_TAG}" > build-report.txt
            cat test-report.xml >> build-report.txt || true
            aws s3 cp build-report.txt s3://${S3_BUCKET}/reports/build-${BUILD_NUMBER}.txt
          '''
        }
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
          sh '''
            export KUBECONFIG=$KUBECONFIG_FILE
            kubectl apply -f k8s/namespace.yaml
            kubectl apply -f k8s/configmap.yaml -n ${KUBE_NAMESPACE}
            kubectl apply -f k8s/secret.yaml   -n ${KUBE_NAMESPACE} || echo "secret must exist already"
            kubectl apply -f k8s/postgres.yaml -n ${KUBE_NAMESPACE}
            # inject the new image tag
            sed "s|IMAGE_PLACEHOLDER|${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/app-deployment.yaml \
              | kubectl apply -n ${KUBE_NAMESPACE} -f -
            kubectl apply -f k8s/app-service.yaml -n ${KUBE_NAMESPACE}
            kubectl rollout status deployment/notes-app -n ${KUBE_NAMESPACE} --timeout=180s
          '''
        }
      }
    }

    stage('Smoke test /health') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
          sh '''
            export KUBECONFIG=$KUBECONFIG_FILE
            NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
            NODE_PORT=$(kubectl get svc notes-app -n ${KUBE_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}')
            for i in 1 2 3 4 5 6 7 8 9 10; do
              code=$(curl -s -o /dev/null -w "%{http_code}" http://${NODE_IP}:${NODE_PORT}/health || true)
              if [ "$code" = "200" ]; then echo "healthy"; exit 0; fi
              echo "waiting... ($i) got=$code"; sleep 5
            done
            echo "health check failed"; exit 1
          '''
        }
      }
    }
  }

  post {
    success { echo "Build ${BUILD_NUMBER} deployed OK" }
    failure { echo "Build ${BUILD_NUMBER} FAILED" }
  }
}

E_O_F_58231b16

# ---- README.md ----
write "README.md" <<'E_O_F_04c6e90f'
# DevOps Notes App — Hands-on Practice Project

A tiny Python/FastAPI notes app, used as a canvas to practice the full DevOps stack:
**Terraform → Ansible → Docker → Jenkins → Kubernetes (k3s) → Prometheus + Grafana**.

The application is deliberately small. The focus is **infrastructure, automation, and
monitoring**.

> ### Two ways to run this
> - **Free local mode (recommended, $0)** — kind + MinIO + Jenkins in-cluster on your
>   laptop. See [`local/README.md`](local/README.md). One command: `./local/setup-local.sh`.
> - **AWS mode** — real EC2 + S3 + k3s, ~$3-5/day if left on. Everything below applies
>   to this mode.

---

## Folder structure

```
devops-notes-app/
├── terraform/          # AWS infra (VPC, EC2 x2, S3, SGs)
├── ansible/            # Server config (Docker, Jenkins, k3s, Helm, kubectl, SSH)
├── app/                # FastAPI notes app + pytest tests
├── k8s/                # Namespace, ConfigMap, Secret, Postgres, Deployment, Service
├── monitoring/         # Helm values, ServiceMonitor, alerts, Grafana dashboard
├── local/              # Zero-cost local stack (kind + MinIO + Jenkins) + LocalStack
├── Dockerfile          # Image for the notes app
├── docker-compose.yml  # Local dev stack (app + Postgres)
├── Jenkinsfile         # CI/CD pipeline
├── .gitignore
└── README.md
```

---

## Architecture

```mermaid
flowchart LR
  Dev[You / git push] --> GH[GitHub repo]
  GH -->|webhook| J[(Jenkins EC2<br/>t3.small)]
  J -->|docker build & push| DH[Docker Hub]
  J -->|aws s3 cp report| S3[(S3 Artifacts Bucket)]
  J -->|kubectl apply| K[(k3s EC2<br/>t3.medium)]
  subgraph K[k3s EC2 - t3.medium]
    direction TB
    NS[Namespace: notes] --> APP[notes-app Deployment<br/>2 replicas :8000]
    APP --> SVC[notes-app Service<br/>NodePort 30080]
    APP --> PG[(Postgres StatefulSet<br/>PVC: 2Gi)]
    NSM[Namespace: monitoring] --> PR[Prometheus]
    NSM --> GR[Grafana :30030]
    NSM --> AM[Alertmanager]
    PR -->|ServiceMonitor| APP
    PR --> GR
  end
  User[You in browser] -->|30080 / 30030| K
```

---

## Costs (warning: NOT fully free-tier)

| Resource | Spec | Monthly if left on 24/7 (us-east-1) |
|---|---|---|
| EC2 jenkins | t3.small (2 vCPU, 2 GiB) | ~$15 |
| EC2 k3s     | t3.medium (2 vCPU, 4 GiB) | ~$30 |
| EBS gp3     | 50 GiB total | ~$4 |
| S3          | <1 GiB | <$1 |
| Data transfer | low | <$1 |

> **t3.medium is NOT free-tier** – only `t3.micro` is. If you want to keep this truly
> free, change `k8s_instance_type = "t3.micro"` in `terraform.tfvars` and skip
> Prometheus/Grafana (it will OOM). Running the project only during practice sessions
> and `terraform destroy` afterwards keeps the cost to a few dollars per month.

---

## Prerequisites on your laptop

```bash
# macOS/Linux
brew install terraform ansible awscli kubectl helm jq
aws configure                    # set your AWS access/secret keys + region
ssh-keygen -t ed25519 -f ~/.ssh/devops-notes   # creates .pub + private key
```

---

## Google OAuth 2.0 login (BYOK)

The app has `/auth/google/login`, `/auth/google/callback`, `/auth/me`, and `/auth/logout`.
`/notes` endpoints are protected — each user sees only their own notes.

### 1) Create the OAuth client (free, in Google Cloud Console)

1. Open **https://console.cloud.google.com/apis/credentials**
2. **CREATE CREDENTIALS → OAuth client ID**
3. Application type: **Web application**
4. **Authorized redirect URIs** — add every URL where you'll run the app:
   - Local kind: `http://localhost:30080/auth/google/callback`
   - AWS EC2 : `http://<K8S_PUBLIC_IP>:30080/auth/google/callback`
   - Any custom domain you attach later: `https://your-domain.com/auth/google/callback`
5. Click **Create** → copy the **Client ID** and **Client Secret**.
6. On the **OAuth consent screen**, add your Google account under **Test users** while
   the app is in Testing mode.

> If you add a custom domain later, you **must** add it to Authorized redirect URIs in
> Google Cloud Console — otherwise OAuth will fail.

### 2) Put the secrets into Kubernetes

Local (kind) — the `local/setup-local.sh` auto-generates `JWT_SECRET` and `SESSION_SECRET`
and reads Google creds from your shell:

```bash
export GOOGLE_CLIENT_ID='...'
export GOOGLE_CLIENT_SECRET='...'
./local/setup-local.sh
```

Already running? Patch and restart:

```bash
kubectl -n notes create secret generic notes-app-secret \
  --from-literal=DB_USER=notes \
  --from-literal=DB_PASSWORD=notes_local_dev \
  --from-literal=GOOGLE_CLIENT_ID=... \
  --from-literal=GOOGLE_CLIENT_SECRET=... \
  --from-literal=JWT_SECRET=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))') \
  --from-literal=SESSION_SECRET=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))') \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n notes rollout restart deploy/notes-app
```

AWS — edit `k8s/secret.yaml.example` → `secret.yaml` (do NOT commit) and
`k8s/configmap.yaml` so `GOOGLE_REDIRECT_URI` and `APP_BASE_URL` point to
`http://<K8S_PUBLIC_IP>:30080/...`.

### 3) Try it

```bash
curl -I http://localhost:30080/auth/google/login       # expect 302 to accounts.google.com
curl    http://localhost:30080/notes                    # expect 401 (not logged in)
# Open the login URL in a browser:
open    http://localhost:30080/auth/google/login
# After the Google redirect, you'll be bounced back with a `notes_session` cookie.
curl -b "notes_session=..." http://localhost:30080/auth/me
```

### Security notes

- `JWT_SECRET` + `SESSION_SECRET` must be strong random strings. Rotate them if leaked.
- The cookie is `httpOnly`, `SameSite=Lax`. Flip `secure=True` in `app/main.py` once
  you serve the app over HTTPS (behind an ingress / ALB / Cloudflare).
- No OAuth client secret ever lives in Git — only in the Kubernetes Secret / `.env`.

---

## Step-by-step setup

### 1) Fill variables and provision AWS infra

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars:
#   my_ip_cidr     = "<your public IP>/32"      # curl ifconfig.me
#   ssh_public_key = "<contents of ~/.ssh/devops-notes.pub>"
terraform init
terraform apply                                  # type: yes
terraform output                                 # note the 2 public IPs + S3 bucket name
```

### 2) Configure servers with Ansible

```bash
cd ../ansible
cp inventory.ini.example inventory.ini
# replace JENKINS_PUBLIC_IP and K8S_PUBLIC_IP with the Terraform outputs
ansible all -m ping
ansible-playbook playbook.yml
```

### 3) Grab the Jenkins initial admin password and the kubeconfig

```bash
# Jenkins
ssh -i ~/.ssh/devops-notes ubuntu@<JENKINS_PUBLIC_IP> \
    'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
# open http://<JENKINS_PUBLIC_IP>:8080 and finish the wizard

# Kubeconfig for your laptop (so you can run kubectl locally)
scp -i ~/.ssh/devops-notes ubuntu@<K8S_PUBLIC_IP>:/home/ubuntu/.kube/config ./kubeconfig
sed -i '' "s/127.0.0.1/<K8S_PUBLIC_IP>/" kubeconfig   # Linux: drop the ''
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

### 4) Deploy the app manually first (to prove the pipeline target works)

```bash
cd ../k8s
cp secret.yaml.example secret.yaml                 # set a strong DB_PASSWORD
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml -n notes
kubectl apply -f secret.yaml    -n notes
kubectl apply -f postgres.yaml  -n notes
# first-time image: just use a public one until Jenkins runs
sed "s|IMAGE_PLACEHOLDER|<YOUR_DOCKERHUB_USER>/notes-app:latest|g" app-deployment.yaml \
  | kubectl apply -n notes -f -
kubectl apply -f app-service.yaml -n notes
kubectl -n notes rollout status deploy/notes-app
curl http://<K8S_PUBLIC_IP>:30080/health          # -> {"status":"ok"}
```

### 5) Install Prometheus + Grafana

```bash
cd ../monitoring
kubectl create namespace monitoring
cp grafana-admin-secret.yaml.example grafana-admin-secret.yaml  # set a password
kubectl apply -f grafana-admin-secret.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
     -n monitoring -f values.yaml
kubectl apply -f servicemonitor.yaml
kubectl apply -f prometheusrule.yaml
kubectl apply -f grafana-dashboard-configmap.yaml
```

### 6) Open the UIs

| What | URL |
|---|---|
| Notes app | `http://<K8S_PUBLIC_IP>:30080` + `/health`, `/metrics`, `/notes` |
| Prometheus | `http://<K8S_PUBLIC_IP>:30090` |
| Grafana | `http://<K8S_PUBLIC_IP>:30030` (login with the Secret) |

In Grafana, open **Dashboards → Notes App Overview** (auto-provisioned).

### 7) Wire up Jenkins

In Jenkins → **Manage Jenkins → Credentials**, add:

| ID | Type | Value |
|---|---|---|
| `dockerhub-creds` | Username+password | your Docker Hub user + token |
| `aws-creds` | AWS credentials | your AWS access/secret keys |
| `kubeconfig` | Secret file | upload the kubeconfig file you downloaded |
| `s3-artifacts-bucket` | Secret text | bucket name from `terraform output` |

Install plugins: *Pipeline, Git, Docker Pipeline, AWS Steps, JUnit*.

Create a **Multibranch Pipeline** or a **Pipeline from SCM** pointing to this repo.
Edit the top of `Jenkinsfile` to replace `YOUR_DOCKERHUB_USER`. Run the pipeline.

### 8) Destroy everything (very important!)

```bash
# first, remove k8s resources if you still want the artifacts
helm -n monitoring uninstall kps || true
kubectl delete namespace notes monitoring || true

cd terraform
terraform destroy
```

---

## Local development (no AWS)

```bash
cp app/.env.example app/.env
docker compose up --build
curl localhost:8000/health
cd app && PYTHONPATH=.. pytest tests
```

---

## 12 practice exercises (easy → hard)

1. **Easy** – Change `replicas: 2` → `3` in `k8s/app-deployment.yaml`, apply, watch rollout.
2. **Easy** – Add a `/version` endpoint to the app, write a test, open a PR, see Jenkins build.
3. **Easy** – Add a Prometheus counter for note creation (`notes_created_total`), expose it.
4. **Medium** – Add a **new Grafana panel** that charts `rate(notes_created_total[5m])`.
5. **Medium** – Add a **new alert rule**: `HighLatencyP95` – fire when p95 > 500ms for 5m.
6. **Medium** – Switch the app Service from `NodePort` to `ClusterIP` and expose it with a
   k3s `Ingress`.
7. **Medium** – Add Horizontal Pod Autoscaler on CPU; load-test with `hey` and watch it scale.
8. **Hard** – Add a second Ansible role to install `fail2ban` and ship its logs to a file
   Prometheus can read via `node_exporter --collector.textfile.directory`.
9. **Hard** – **Break the app on purpose**: `kubectl -n notes scale deploy notes-app --replicas=0`.
   Watch `AppDown` fire. Then set a bad `IMAGE_PLACEHOLDER` tag and watch `CrashLoopBackOff` +
   see the alert. Then flood `/notes` POSTs that 500 (point `DB_HOST` to a wrong value) and
   watch `HighErrorRate` fire.
10. **Hard** – Add a nightly `CronJob` that `pg_dump`s Postgres and `aws s3 cp`s it to S3.
11. **Hard** – Split Terraform into `modules/vpc`, `modules/compute`, `modules/s3` and use
    them from `terraform/main.tf`.
12. **Hard** – Replace the single-node k3s with **k3s HA** (3 server nodes) via Terraform
    and update Ansible to configure the join tokens.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `terraform apply` fails on AMI | Pin a current Ubuntu 22.04 AMI for your region: `aws ec2 describe-images --owners 099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' --query 'Images|sort_by(@,&CreationDate)[-1].ImageId'` |
| Ansible `UNREACHABLE` | Check the SG allows your IP; check `ansible_user=ubuntu`; private key perms must be `600`. |
| `kubectl` says `localhost:8080 refused` | You forgot `export KUBECONFIG=...` or didn't replace `127.0.0.1` with the public IP in the kubeconfig. |
| Pods stay `Pending` | `kubectl describe pod ...` – usually not enough memory on `t3.medium`; try smaller `resources.requests`. |
| ServiceMonitor not scraped | Label `release: kps` on the SM **and** service port named `http`. Check **Prometheus → Status → Targets**. |
| Grafana shows "no data" | Open **Explore** and run `up{job="notes-app"}` – if empty, SM selector doesn't match the service labels. |
| Jenkins can't `kubectl` | `kubeconfig` credential file wasn't uploaded, or the k3s SG doesn't allow 6443 from the Jenkins SG. |
| Docker push fails | Create a Docker Hub access token and store it in `dockerhub-creds`. |
| `terraform destroy` fails on S3 | S3 bucket not empty: it has `force_destroy = true`, but if versioning left markers, empty manually: `aws s3 rm s3://<bucket> --recursive`. |

---

## Security rules this project follows

- No passwords, keys or tokens in code – all come from `.env`, Jenkins credentials, or
  Kubernetes Secrets (`notes-app-secret`, `grafana-admin`).
- SSH is restricted to **your IP only** (`my_ip_cidr`).
- Only ports **22, 8080, 30030, 30080, 30090** and k3s `6443` (SG-to-SG) are open.
- S3 bucket blocks all public access and has versioning enabled.
- `.gitignore` excludes `.env`, `*.tfstate`, `*.tfvars`, `*.pem`.

Happy breaking (and fixing) things!

E_O_F_04c6e90f

# ---- ansible/ansible.cfg ----
write "ansible/ansible.cfg" <<'E_O_F_233067f8'
[defaults]
host_key_checking = False
inventory         = inventory.ini
retry_files_enabled = False
stdout_callback   = yaml
roles_path        = roles

E_O_F_233067f8

# ---- ansible/inventory.ini.example ----
write "ansible/inventory.ini.example" <<'E_O_F_ba682aaa'
[jenkins]
jenkins ansible_host=JENKINS_PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/devops-notes.pem

[k8s]
k8s ansible_host=K8S_PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/devops-notes.pem

[all:vars]
ansible_python_interpreter=/usr/bin/python3

E_O_F_ba682aaa

# ---- ansible/playbook.yml ----
write "ansible/playbook.yml" <<'E_O_F_cd63c842'
---
- name: Base hardening on all nodes
  hosts: all
  become: true
  roles:
    - common
    - ssh_hardening

- name: Configure Jenkins host
  hosts: jenkins
  become: true
  roles:
    - docker
    - jenkins

- name: Configure Kubernetes node
  hosts: k8s
  become: true
  roles:
    - docker
    - k3s
    - helm

E_O_F_cd63c842

# ---- ansible/roles/common/tasks/main.yml ----
write "ansible/roles/common/tasks/main.yml" <<'E_O_F_1ce6d209'
---
- name: Update apt cache
  apt:
    update_cache: yes
    cache_valid_time: 3600

- name: Install baseline packages
  apt:
    name:
      - curl
      - wget
      - git
      - unzip
      - vim
      - ca-certificates
      - gnupg
      - lsb-release
      - python3-pip
      - jq
    state: present

E_O_F_1ce6d209

# ---- ansible/roles/docker/tasks/main.yml ----
write "ansible/roles/docker/tasks/main.yml" <<'E_O_F_8a4c758b'
---
- name: Add Docker GPG key
  apt_key:
    url: https://download.docker.com/linux/ubuntu/gpg
    state: present

- name: Add Docker apt repository
  apt_repository:
    repo: "deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    state: present
    filename: docker

- name: Install Docker Engine
  apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present
    update_cache: yes

- name: Ensure docker service is enabled and started
  service:
    name: docker
    enabled: yes
    state: started

- name: Add ubuntu user to docker group
  user:
    name: ubuntu
    groups: docker
    append: yes

E_O_F_8a4c758b

# ---- ansible/roles/helm/tasks/main.yml ----
write "ansible/roles/helm/tasks/main.yml" <<'E_O_F_658e67ec'
---
- name: Install Helm
  shell: |
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  args:
    creates: /usr/local/bin/helm

E_O_F_658e67ec

# ---- ansible/roles/jenkins/handlers/main.yml ----
write "ansible/roles/jenkins/handlers/main.yml" <<'E_O_F_cfba880c'
---
- name: Restart jenkins
  service:
    name: jenkins
    state: restarted

E_O_F_cfba880c

# ---- ansible/roles/jenkins/tasks/main.yml ----
write "ansible/roles/jenkins/tasks/main.yml" <<'E_O_F_8d62da0f'
---
- name: Install OpenJDK 17
  apt:
    name: openjdk-17-jre
    state: present

- name: Add Jenkins apt key
  get_url:
    url: https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    dest: /usr/share/keyrings/jenkins-keyring.asc
    mode: '0644'

- name: Add Jenkins apt repository
  apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/"
    state: present
    filename: jenkins

- name: Install Jenkins
  apt:
    name: jenkins
    state: present
    update_cache: yes

- name: Ensure Jenkins is running
  service:
    name: jenkins
    state: started
    enabled: yes

- name: Install kubectl (for Jenkins to deploy to k3s)
  shell: |
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
  args:
    creates: /usr/local/bin/kubectl

- name: Install AWS CLI v2
  shell: |
    curl -sLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
  args:
    creates: /usr/local/bin/aws

- name: Add jenkins user to docker group
  user:
    name: jenkins
    groups: docker
    append: yes
  notify: Restart jenkins

E_O_F_8d62da0f

# ---- ansible/roles/k3s/tasks/main.yml ----
write "ansible/roles/k3s/tasks/main.yml" <<'E_O_F_fc5d2c6e'
---
- name: Install k3s (single-node, write kubeconfig world-readable)
  shell: |
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_EXEC="--write-kubeconfig-mode=644 --disable traefik" \
      sh -
  args:
    creates: /usr/local/bin/k3s

- name: Wait for kubeconfig to appear
  wait_for:
    path: /etc/rancher/k3s/k3s.yaml
    timeout: 60

- name: Install kubectl symlink
  file:
    src: /usr/local/bin/k3s
    dest: /usr/local/bin/kubectl
    state: link
    force: yes

- name: Create ubuntu .kube dir
  file:
    path: /home/ubuntu/.kube
    state: directory
    owner: ubuntu
    group: ubuntu
    mode: '0755'

- name: Copy kubeconfig for ubuntu user
  copy:
    src: /etc/rancher/k3s/k3s.yaml
    dest: /home/ubuntu/.kube/config
    remote_src: yes
    owner: ubuntu
    group: ubuntu
    mode: '0600'

E_O_F_fc5d2c6e

# ---- ansible/roles/ssh_hardening/handlers/main.yml ----
write "ansible/roles/ssh_hardening/handlers/main.yml" <<'E_O_F_4ba43c3b'
---
- name: Restart sshd
  service:
    name: ssh
    state: restarted

E_O_F_4ba43c3b

# ---- ansible/roles/ssh_hardening/tasks/main.yml ----
write "ansible/roles/ssh_hardening/tasks/main.yml" <<'E_O_F_734c32c7'
---
- name: Disable password authentication
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PasswordAuthentication'
    line: 'PasswordAuthentication no'
    state: present
  notify: Restart sshd

- name: Disable root login
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PermitRootLogin'
    line: 'PermitRootLogin no'
    state: present
  notify: Restart sshd

E_O_F_734c32c7

# ---- app/.env.example ----
write "app/.env.example" <<'E_O_F_0641699f'
# ---- Database ----
DB_HOST=postgres
DB_PORT=5432
DB_NAME=notes
DB_USER=notes
DB_PASSWORD=change_me

# ---- Google OAuth 2.0 (BYOK) ----
# Create at: https://console.cloud.google.com/apis/credentials -> OAuth client ID (Web application)
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=

# The redirect URI you register in Google Cloud Console. Examples:
#   Local  : http://localhost:30080/auth/google/callback
#   EC2    : http://<EC2_PUBLIC_IP>:30080/auth/google/callback
# REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
GOOGLE_REDIRECT_URI=http://localhost:30080/auth/google/callback
APP_BASE_URL=http://localhost:30080

# ---- JWT & session (generate 32+ random bytes each) ----
JWT_SECRET=change_me_32_bytes
SESSION_SECRET=change_me_32_bytes

E_O_F_0641699f

# ---- app/main.py ----
write "app/main.py" <<'E_O_F_4dd44bb1'
"""FastAPI Notes app with Prometheus metrics and Google OAuth login."""
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import List, Optional

import jwt
from authlib.integrations.starlette_client import OAuth, OAuthError
from fastapi import Cookie, Depends, FastAPI, HTTPException, Request
from fastapi.responses import RedirectResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel
import psycopg2
from psycopg2.extras import RealDictCursor
from starlette.middleware.sessions import SessionMiddleware

# ---- Config (all from env) ----
GOOGLE_CLIENT_ID     = os.environ.get("GOOGLE_CLIENT_ID", "")
GOOGLE_CLIENT_SECRET = os.environ.get("GOOGLE_CLIENT_SECRET", "")
# REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
GOOGLE_REDIRECT_URI  = os.environ.get("GOOGLE_REDIRECT_URI", "")      # e.g. http://localhost:30080/auth/google/callback
APP_BASE_URL         = os.environ.get("APP_BASE_URL", "")             # e.g. http://localhost:30080
JWT_SECRET           = os.environ.get("JWT_SECRET", "dev-insecure-change-me")
SESSION_SECRET       = os.environ.get("SESSION_SECRET", "dev-insecure-change-me-session")
JWT_ALG              = "HS256"
JWT_TTL_HOURS        = 24
COOKIE_NAME          = "notes_session"

# ---- Prometheus metrics ----
REQUEST_COUNT = Counter(
    "notes_app_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "http_status"],
)
REQUEST_LATENCY = Histogram(
    "notes_app_request_duration_seconds",
    "Request duration in seconds",
    ["method", "endpoint"],
)

# ---- DB ----
def get_conn():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "notes"),
        user=os.environ.get("DB_USER", "notes"),
        password=os.environ.get("DB_PASSWORD", "notes"),
    )

def init_db():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    google_sub TEXT UNIQUE NOT NULL,
                    email TEXT NOT NULL,
                    name TEXT,
                    picture TEXT,
                    created_at TIMESTAMPTZ DEFAULT now()
                );
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id SERIAL PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL DEFAULT ''
                );
            """)
            conn.commit()
    except Exception as e:  # noqa: BLE001
        print(f"[init_db] skipped: {e}")

@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield

app = FastAPI(title="Notes App", lifespan=lifespan)
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET)

# ---- OAuth client (Google) ----
oauth = OAuth()
oauth.register(
    name="google",
    client_id=GOOGLE_CLIENT_ID,
    client_secret=GOOGLE_CLIENT_SECRET,
    server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
    client_kwargs={"scope": "openid email profile"},
)

# ---- Metrics middleware ----
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    elapsed = time.time() - start
    endpoint = request.url.path
    REQUEST_COUNT.labels(request.method, endpoint, response.status_code).inc()
    REQUEST_LATENCY.labels(request.method, endpoint).observe(elapsed)
    return response

# ---- JWT helpers ----
def issue_jwt(user_id: int, email: str) -> str:
    payload = {
        "sub": str(user_id),
        "email": email,
        "exp": datetime.now(timezone.utc) + timedelta(hours=JWT_TTL_HOURS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)

def decode_jwt(token: str) -> dict:
    return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])

def get_current_user(
    notes_session: Optional[str] = Cookie(default=None, alias=COOKIE_NAME),
) -> dict:
    if not notes_session:
        raise HTTPException(status_code=401, detail="not authenticated")
    try:
        claims = decode_jwt(notes_session)
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="invalid session")
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, email, name, picture FROM users WHERE id = %s;",
            (int(claims["sub"]),),
        )
        user = cur.fetchone()
    if not user:
        raise HTTPException(status_code=401, detail="user not found")
    return user

# ---- Models ----
class NoteIn(BaseModel):
    title: str
    body: str = ""

class Note(NoteIn):
    id: int

# ---- Public routes ----
@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/")
def root():
    login_url = "/auth/google/login" if GOOGLE_CLIENT_ID else None
    return {"service": "notes-app", "version": "1.0.0", "login": login_url}

# ---- Auth routes ----
@app.get("/auth/google/login")
async def google_login(request: Request):
    if not GOOGLE_CLIENT_ID:
        raise HTTPException(status_code=503, detail="Google OAuth not configured")
    # REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
    redirect_uri = GOOGLE_REDIRECT_URI or str(request.url_for("google_callback"))
    return await oauth.google.authorize_redirect(request, redirect_uri)

@app.get("/auth/google/callback", name="google_callback")
async def google_callback(request: Request):
    try:
        token = await oauth.google.authorize_access_token(request)
    except OAuthError as e:
        raise HTTPException(status_code=400, detail=f"oauth error: {e.error}")

    userinfo = token.get("userinfo") or {}
    sub     = userinfo.get("sub")
    email   = userinfo.get("email")
    name    = userinfo.get("name")
    picture = userinfo.get("picture")
    if not sub or not email:
        raise HTTPException(status_code=400, detail="invalid id_token")

    # Upsert user by google_sub
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """
            INSERT INTO users (google_sub, email, name, picture)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (google_sub)
            DO UPDATE SET email = EXCLUDED.email,
                          name = EXCLUDED.name,
                          picture = EXCLUDED.picture
            RETURNING id, email;
            """,
            (sub, email, name, picture),
        )
        user = cur.fetchone()
        conn.commit()

    jwt_token = issue_jwt(user["id"], user["email"])
    resp = RedirectResponse(url=APP_BASE_URL or "/", status_code=302)
    resp.set_cookie(
        key=COOKIE_NAME,
        value=jwt_token,
        max_age=JWT_TTL_HOURS * 3600,
        httponly=True,
        samesite="lax",
        secure=False,   # set True once you serve the app over HTTPS
        path="/",
    )
    return resp

@app.get("/auth/me")
def auth_me(current=Depends(get_current_user)):
    return current

@app.post("/auth/logout")
def auth_logout():
    resp = Response(status_code=204)
    resp.delete_cookie(COOKIE_NAME, path="/")
    return resp

# ---- Protected notes routes (per-user) ----
@app.get("/notes", response_model=List[Note])
def list_notes(current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, title, body FROM notes WHERE user_id = %s ORDER BY id DESC;",
            (current["id"],),
        )
        return cur.fetchall()

@app.post("/notes", response_model=Note, status_code=201)
def create_note(note: NoteIn, current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "INSERT INTO notes (user_id, title, body) VALUES (%s, %s, %s) "
            "RETURNING id, title, body;",
            (current["id"], note.title, note.body),
        )
        row = cur.fetchone()
        conn.commit()
        return row

@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: int, current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM notes WHERE id = %s AND user_id = %s RETURNING id;",
            (note_id, current["id"]),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="not found")
        conn.commit()
    return Response(status_code=204)

E_O_F_4dd44bb1

# ---- app/requirements.txt ----
write "app/requirements.txt" <<'E_O_F_fbafa449'
fastapi==0.115.5
uvicorn[standard]==0.32.1
pydantic==2.9.2
prometheus-client==0.21.0
psycopg2-binary==2.9.10
Authlib==1.3.2
itsdangerous==2.2.0
PyJWT==2.9.0
httpx==0.27.2
pytest==8.3.3

E_O_F_fbafa449

# ---- app/tests/test_main.py ----
write "app/tests/test_main.py" <<'E_O_F_93839593'
"""Basic pytest tests for the Notes app."""
import os
os.environ.setdefault("DB_HOST", "127.0.0.1")      # init_db swallows errors on failure

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}

def test_metrics_exposes_prometheus():
    r = client.get("/metrics")
    assert r.status_code == 200
    body = r.text
    assert "notes_app_requests_total" in body
    assert "notes_app_request_duration_seconds" in body

def test_notes_requires_auth():
    r = client.get("/notes")
    assert r.status_code == 401

E_O_F_93839593

# ---- docker-compose.yml ----
write "docker-compose.yml" <<'E_O_F_4e5e90c6'
version: "3.9"
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${DB_USER:-notes}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-notes}
      POSTGRES_DB: ${DB_NAME:-notes}
    ports: ["5432:5432"]
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-notes}"]
      interval: 5s
      timeout: 3s
      retries: 10

  app:
    build: .
    env_file: ./app/.env
    environment:
      DB_HOST: postgres
    depends_on:
      postgres:
        condition: service_healthy
    ports: ["8000:8000"]

volumes:
  pgdata: {}

E_O_F_4e5e90c6

# ---- k8s/app-deployment.yaml ----
write "k8s/app-deployment.yaml" <<'E_O_F_03fc8f0c'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes-app
  namespace: notes
  labels:
    app: notes-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: notes-app }
  template:
    metadata:
      labels: { app: notes-app }
    spec:
      containers:
        - name: app
          # Replaced by Jenkins at deploy time (sed IMAGE_PLACEHOLDER).
          image: IMAGE_PLACEHOLDER
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8000
          envFrom:
            - configMapRef: { name: notes-app-config }
            - secretRef:    { name: notes-app-secret }
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 15
            periodSeconds: 15
          resources:
            requests: { cpu: "50m",  memory: "96Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }

E_O_F_03fc8f0c

# ---- k8s/app-service.yaml ----
write "k8s/app-service.yaml" <<'E_O_F_2230989e'
apiVersion: v1
kind: Service
metadata:
  name: notes-app
  namespace: notes
  labels:
    app: notes-app
spec:
  type: NodePort
  selector: { app: notes-app }
  ports:
    - name: http
      port: 80
      targetPort: 8000
      nodePort: 30080

E_O_F_2230989e

# ---- k8s/configmap.yaml ----
write "k8s/configmap.yaml" <<'E_O_F_b2f5e663'
apiVersion: v1
kind: ConfigMap
metadata:
  name: notes-app-config
  namespace: notes
data:
  DB_HOST: postgres
  DB_PORT: "5432"
  DB_NAME: notes
  # Edit these for your target. For AWS, use http://<K8S_PUBLIC_IP>:30080/...
  # REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
  GOOGLE_REDIRECT_URI: "http://localhost:30080/auth/google/callback"
  APP_BASE_URL: "http://localhost:30080"

E_O_F_b2f5e663

# ---- k8s/namespace.yaml ----
write "k8s/namespace.yaml" <<'E_O_F_0c81e32f'
apiVersion: v1
kind: Namespace
metadata:
  name: notes
  labels:
    name: notes
    monitoring: "true"

E_O_F_0c81e32f

# ---- k8s/postgres.yaml ----
write "k8s/postgres.yaml" <<'E_O_F_57166a4c'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: notes
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 2Gi
  # k3s ships with a "local-path" default StorageClass
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: notes
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              valueFrom: { configMapKeyRef: { name: notes-app-config, key: DB_NAME } }
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: notes-app-secret, key: DB_USER } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: notes-app-secret, key: DB_PASSWORD } }
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "notes"]
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "notes"]
            initialDelaySeconds: 20
            periodSeconds: 20
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "384Mi" }
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: notes
spec:
  selector: { app: postgres }
  ports:
    - port: 5432
      targetPort: 5432

E_O_F_57166a4c

# ---- k8s/secret.yaml.example ----
write "k8s/secret.yaml.example" <<'E_O_F_148bdeca'
# Copy to secret.yaml, replace values, DO NOT COMMIT.
# Generate strong random values for JWT_SECRET and SESSION_SECRET, e.g.:
#   python -c "import secrets; print(secrets.token_urlsafe(32))"
apiVersion: v1
kind: Secret
metadata:
  name: notes-app-secret
  namespace: notes
type: Opaque
stringData:
  DB_USER: notes
  DB_PASSWORD: CHANGE_ME_STRONG_PASSWORD
  GOOGLE_CLIENT_ID: CHANGE_ME_GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_SECRET: CHANGE_ME_GOOGLE_CLIENT_SECRET
  JWT_SECRET: CHANGE_ME_RANDOM_32_BYTES
  SESSION_SECRET: CHANGE_ME_RANDOM_32_BYTES

E_O_F_148bdeca

# ---- local/README.md ----
write "local/README.md" <<'E_O_F_44ba28fa'
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

E_O_F_44ba28fa

# ---- local/jenkins.yaml ----
write "local/jenkins.yaml" <<'E_O_F_4dedcf7e'
# Jenkins LTS running inside kind. Reachable at http://localhost:8080.
apiVersion: v1
kind: Namespace
metadata: { name: jenkins }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: jenkins, namespace: jenkins }
---
# Give Jenkins the rights it needs to deploy into the 'notes' namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: jenkins-admin }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: jenkins-home, namespace: jenkins }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 3Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: jenkins, namespace: jenkins }
spec:
  replicas: 1
  selector: { matchLabels: { app: jenkins } }
  template:
    metadata: { labels: { app: jenkins } }
    spec:
      serviceAccountName: jenkins
      securityContext: { fsGroup: 1000 }
      containers:
        - name: jenkins
          image: jenkins/jenkins:lts-jdk17
          ports:
            - { containerPort: 8080, name: http }
            - { containerPort: 50000, name: agent }
          env:
            - name: JAVA_OPTS
              value: "-Djenkins.install.runSetupWizard=false -Xmx768m"
          volumeMounts:
            - { name: home, mountPath: /var/jenkins_home }
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: 1,    memory: 1024Mi }
      volumes:
        - name: home
          persistentVolumeClaim: { claimName: jenkins-home }
---
apiVersion: v1
kind: Service
metadata: { name: jenkins, namespace: jenkins }
spec:
  type: NodePort
  selector: { app: jenkins }
  ports:
    - { name: http,  port: 8080,  targetPort: 8080,  nodePort: 30808 }
    - { name: agent, port: 50000, targetPort: 50000 }

E_O_F_4dedcf7e

# ---- local/kind-cluster.yaml ----
write "local/kind-cluster.yaml" <<'E_O_F_4579434e'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devops-notes
nodes:
  - role: control-plane
    extraPortMappings:
      # notes-app NodePort -> host
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      # Grafana NodePort -> host
      - containerPort: 30030
        hostPort: 30030
        protocol: TCP
      # Prometheus NodePort -> host
      - containerPort: 30090
        hostPort: 30090
        protocol: TCP
      # Jenkins NodePort -> host
      - containerPort: 30808
        hostPort: 8080
        protocol: TCP
      # MinIO console -> host
      - containerPort: 30901
        hostPort: 9001
        protocol: TCP
      # MinIO API (S3) -> host
      - containerPort: 30900
        hostPort: 9000
        protocol: TCP
  - role: worker

E_O_F_4579434e

# ---- local/localstack-compose.yml ----
write "local/localstack-compose.yml" <<'E_O_F_1702d58b'
# LocalStack = AWS emulator. Lets you practice Terraform `apply`/`destroy`
# against VPC/EC2/S3 for free. Run:  docker compose -f local/localstack-compose.yml up -d
version: "3.9"
services:
  localstack:
    image: localstack/localstack:3.8
    ports:
      - "4566:4566"           # single edge port for all AWS services
    environment:
      SERVICES: s3,ec2,iam
      DEFAULT_REGION: us-east-1
      DEBUG: "0"
    volumes:
      - localstack_data:/var/lib/localstack
volumes:
  localstack_data: {}

E_O_F_1702d58b

# ---- local/localstack.tfvars ----
write "local/localstack.tfvars" <<'E_O_F_98d5b95e'
# Drop-in override: `terraform -chdir=terraform plan -var-file=../local/localstack.tfvars`.
# NOTE: pair this with the local/provider_override.tf symlink the setup script creates.
aws_region         = "us-east-1"
my_ip_cidr         = "0.0.0.0/0"
ssh_public_key     = "ssh-ed25519 AAAA_DUMMY_FOR_LOCALSTACK"
jenkins_instance_type = "t3.small"
k8s_instance_type     = "t3.medium"

E_O_F_98d5b95e

# ---- local/minio.yaml ----
write "local/minio.yaml" <<'E_O_F_9d74f8b7'
# MinIO = free, S3-compatible object storage. Used as the "artifacts bucket".
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-root
  namespace: minio
type: Opaque
stringData:
  rootUser: minioadmin
  rootPassword: minioadmin123
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      containers:
        - name: minio
          image: minio/minio:RELEASE.2024-10-13T13-34-11Z
          args: ["server", "/data", "--console-address", ":9001"]
          ports:
            - { containerPort: 9000, name: s3 }
            - { containerPort: 9001, name: console }
          env:
            - name: MINIO_ROOT_USER
              valueFrom: { secretKeyRef: { name: minio-root, key: rootUser } }
            - name: MINIO_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: minio-root, key: rootPassword } }
          volumeMounts:
            - { name: data, mountPath: /data }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 384Mi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: minio-pvc }
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  type: NodePort
  selector: { app: minio }
  ports:
    - { name: s3,      port: 9000, targetPort: 9000, nodePort: 30900 }
    - { name: console, port: 9001, targetPort: 9001, nodePort: 30901 }

E_O_F_9d74f8b7

# ---- local/provider_override.tf ----
write "local/provider_override.tf" <<'E_O_F_917c48ab'
# Copy this into terraform/ as `provider_override.tf` to redirect to LocalStack.
# (Only when practicing locally. Delete before real AWS use.)
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    s3  = "http://localhost:4566"
    ec2 = "http://localhost:4566"
    iam = "http://localhost:4566"
  }
}

E_O_F_917c48ab

# ---- local/setup-local.sh ----
write "local/setup-local.sh" <<'E_O_F_02d6d0db'
#!/usr/bin/env bash
# Zero-cost local DevOps stack: kind + MinIO + Jenkins + Postgres + Prometheus + Grafana.
# Prereqs on your laptop: docker, kind, kubectl, helm.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not installed"; exit 1; }; }
need docker; need kind; need kubectl; need helm

CLUSTER=devops-notes
IMAGE_TAG="${IMAGE_TAG:-local}"
IMAGE="notes-app:${IMAGE_TAG}"

echo ">>> 1/7  Creating kind cluster '$CLUSTER' (idempotent)..."
if ! kind get clusters | grep -q "^${CLUSTER}$"; then
  kind create cluster --config "$HERE/kind-cluster.yaml"
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

echo ">>> 2/7  Building notes-app image & loading into kind..."
docker build -t "$IMAGE" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo ">>> 3/7  Deploying Postgres + notes-app..."
kubectl apply -f "$ROOT/k8s/namespace.yaml"
kubectl apply -f "$ROOT/k8s/configmap.yaml" -n notes
# Create a local secret with dev values if missing.
# Google OAuth: set these two env vars before running the script, OR edit the secret
# afterwards with `kubectl -n notes edit secret notes-app-secret`:
#   export GOOGLE_CLIENT_ID=...
#   export GOOGLE_CLIENT_SECRET=...
JWT_SECRET_VAL="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SESSION_SECRET_VAL="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
kubectl -n notes get secret notes-app-secret >/dev/null 2>&1 || \
  kubectl -n notes create secret generic notes-app-secret \
    --from-literal=DB_USER=notes \
    --from-literal=DB_PASSWORD=notes_local_dev \
    --from-literal=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
    --from-literal=GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
    --from-literal=JWT_SECRET="${JWT_SECRET_VAL}" \
    --from-literal=SESSION_SECRET="${SESSION_SECRET_VAL}"
kubectl apply -f "$ROOT/k8s/postgres.yaml" -n notes
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" "$ROOT/k8s/app-deployment.yaml" \
  | kubectl apply -n notes -f -
kubectl apply -f "$ROOT/k8s/app-service.yaml" -n notes
kubectl -n notes rollout status deploy/notes-app --timeout=180s

echo ">>> 4/7  Deploying MinIO (S3-compatible artifact store)..."
kubectl apply -f "$HERE/minio.yaml"
kubectl -n minio rollout status deploy/minio --timeout=120s

echo ">>> 5/7  Deploying Jenkins in-cluster..."
kubectl apply -f "$HERE/jenkins.yaml"
kubectl -n jenkins rollout status deploy/jenkins --timeout=240s

echo ">>> 6/7  Installing kube-prometheus-stack + ServiceMonitor + alerts + dashboard..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password=admin_local_dev
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f "$ROOT/monitoring/values.yaml" --wait --timeout 10m
kubectl apply -f "$ROOT/monitoring/servicemonitor.yaml"
kubectl apply -f "$ROOT/monitoring/prometheusrule.yaml"
kubectl apply -f "$ROOT/monitoring/grafana-dashboard-configmap.yaml"

echo ">>> 7/7  Smoke test..."
sleep 3
curl -fsS http://localhost:30080/health && echo

cat <<EOF

======================================================================
  Zero-cost DevOps stack is UP. Open these in your browser:

    Notes app        http://localhost:30080  ( /health /metrics /auth/google/login /notes )
    Jenkins          http://localhost:8080   (setup wizard will run)
    Grafana          http://localhost:30030  (admin / admin_local_dev)
    Prometheus       http://localhost:30090
    MinIO console    http://localhost:9001   (minioadmin / minioadmin123)

  Google OAuth:
    1. Google Cloud Console -> APIs & Services -> Credentials -> Create OAuth client ID
       Application type: Web application
       Authorized redirect URI:  http://localhost:30080/auth/google/callback
    2. kubectl -n notes edit secret notes-app-secret
       Fill GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (base64-encode manually, or
       recreate the secret via kubectl create secret generic with --from-literal).
    3. kubectl -n notes rollout restart deploy/notes-app
    4. Open http://localhost:30080/auth/google/login

  Tear everything down:  ./local/teardown-local.sh
======================================================================
EOF

E_O_F_02d6d0db

# ---- local/teardown-local.sh ----
write "local/teardown-local.sh" <<'E_O_F_78d42ef2'
#!/usr/bin/env bash
# Delete the whole local kind cluster. (Safe: AWS is not touched.)
set -euo pipefail
kind delete cluster --name devops-notes
echo "kind cluster 'devops-notes' deleted."

E_O_F_78d42ef2

# ---- monitoring/grafana-admin-secret.yaml.example ----
write "monitoring/grafana-admin-secret.yaml.example" <<'E_O_F_83200030'
# Copy to grafana-admin-secret.yaml, replace, DO NOT COMMIT.
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: CHANGE_ME_STRONG_PASSWORD

E_O_F_83200030

# ---- monitoring/grafana-dashboard-configmap.yaml ----
write "monitoring/grafana-dashboard-configmap.yaml" <<'E_O_F_4f43d42e'
apiVersion: v1
kind: ConfigMap
metadata:
  name: notes-app-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  notes-app.json: |
    {
      "title": "Notes App Overview",
      "uid": "notes-app",
      "schemaVersion": 38,
      "version": 1,
      "editable": true,
      "timezone": "",
      "time": { "from": "now-30m", "to": "now" },
      "refresh": "30s",
      "panels": [
        {
          "type": "timeseries",
          "title": "Request rate (req/s)",
          "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
          "targets": [{
            "expr": "sum(rate(notes_app_requests_total[1m])) by (endpoint)",
            "legendFormat": "{{endpoint}}",
            "refId": "A"
          }]
        },
        {
          "type": "timeseries",
          "title": "Error rate (5xx %)",
          "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
          "targets": [{
            "expr": "100 * sum(rate(notes_app_requests_total{http_status=~\"5..\"}[5m])) / sum(rate(notes_app_requests_total[5m]))",
            "legendFormat": "error %",
            "refId": "A"
          }],
          "fieldConfig": { "defaults": { "unit": "percent" } }
        },
        {
          "type": "timeseries",
          "title": "Request latency p95 (s)",
          "gridPos": { "x": 0, "y": 8, "w": 12, "h": 8 },
          "targets": [{
            "expr": "histogram_quantile(0.95, sum(rate(notes_app_request_duration_seconds_bucket[5m])) by (le, endpoint))",
            "legendFormat": "p95 {{endpoint}}",
            "refId": "A"
          }],
          "fieldConfig": { "defaults": { "unit": "s" } }
        },
        {
          "type": "timeseries",
          "title": "Pod CPU (cores)",
          "gridPos": { "x": 12, "y": 8, "w": 12, "h": 8 },
          "targets": [{
            "expr": "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"notes\", pod=~\"notes-app.*\"}[2m]))",
            "legendFormat": "{{pod}}",
            "refId": "A"
          }]
        },
        {
          "type": "timeseries",
          "title": "Pod memory (bytes)",
          "gridPos": { "x": 0, "y": 16, "w": 24, "h": 8 },
          "targets": [{
            "expr": "sum by (pod) (container_memory_working_set_bytes{namespace=\"notes\", pod=~\"notes-app.*\"})",
            "legendFormat": "{{pod}}",
            "refId": "A"
          }],
          "fieldConfig": { "defaults": { "unit": "bytes" } }
        }
      ]
    }

E_O_F_4f43d42e

# ---- monitoring/prometheusrule.yaml ----
write "monitoring/prometheusrule.yaml" <<'E_O_F_8fa21c44'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: notes-app-rules
  namespace: monitoring
  labels:
    release: kps
spec:
  groups:
    - name: notes-app.rules
      interval: 30s
      rules:
        - alert: AppDown
          expr: up{job="notes-app"} == 0
          for: 1m
          labels: { severity: critical }
          annotations:
            summary: "Notes app is DOWN"
            description: "No Prometheus targets are up for the notes-app for >1m."

        - alert: HighErrorRate
          expr: |
            sum(rate(notes_app_requests_total{http_status=~"5.."}[5m]))
              /
            sum(rate(notes_app_requests_total[5m])) > 0.05
          for: 2m
          labels: { severity: warning }
          annotations:
            summary: "Notes app error rate > 5%"
            description: "More than 5% of requests are failing over the last 5 minutes."

        - alert: HighMemoryUsage
          expr: |
            sum by (pod) (container_memory_working_set_bytes{namespace="notes", pod=~"notes-app.*"})
              /
            sum by (pod) (kube_pod_container_resource_limits{namespace="notes", pod=~"notes-app.*", resource="memory"}) > 0.85
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "Notes app pod memory > 85% of limit"
            description: "Pod {{ $labels.pod }} is using more than 85% of its memory limit."

E_O_F_8fa21c44

# ---- monitoring/servicemonitor.yaml ----
write "monitoring/servicemonitor.yaml" <<'E_O_F_c4632623'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: notes-app
  namespace: monitoring
  labels:
    release: kps          # must match kube-prometheus-stack release name
spec:
  namespaceSelector:
    matchNames: ["notes"]
  selector:
    matchLabels:
      app: notes-app
  endpoints:
    - port: http
      path: /metrics
      interval: 15s

E_O_F_c4632623

# ---- monitoring/values.yaml ----
write "monitoring/values.yaml" <<'E_O_F_6c536612'
# Lean values for kube-prometheus-stack on a single small node (t3.medium).
# Install:
#   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#   helm repo update
#   kubectl create namespace monitoring
#   kubectl -n monitoring apply -f monitoring/grafana-admin-secret.yaml
#   helm upgrade --install kps prometheus-community/kube-prometheus-stack \
#        -n monitoring -f monitoring/values.yaml

fullnameOverride: kps

alertmanager:
  enabled: true
  alertmanagerSpec:
    resources:
      requests: { cpu: 20m, memory: 64Mi }
      limits:   { cpu: 200m, memory: 128Mi }

prometheus:
  prometheusSpec:
    retention: 2d
    resources:
      requests: { cpu: 100m, memory: 400Mi }
      limits:   { cpu: 500m, memory: 900Mi }
    # Pick up ServiceMonitors from ALL namespaces (so our app's SM is found).
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
  service:
    type: NodePort
    nodePort: 30090

grafana:
  # Password comes from the Kubernetes Secret `grafana-admin` (see grafana-admin-secret.yaml.example).
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  service:
    type: NodePort
    nodePort: 30030
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 300m, memory: 256Mi }
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
      label: grafana_dashboard
      labelValue: "1"
    datasources:
      enabled: true
  defaultDashboardsEnabled: true

kubeStateMetrics:
  enabled: true
nodeExporter:
  enabled: true

# Trim things we don't need on a single-node cluster
kubeEtcd: { enabled: false }
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeProxy: { enabled: false }

E_O_F_6c536612

# ---- terraform/ec2.tf ----
write "terraform/ec2.tf" <<'E_O_F_ccf5a12a'
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = var.ssh_public_key
}

resource "aws_instance" "jenkins" {
  ami                         = var.ami_id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-jenkins", Role = "jenkins" }
}

resource "aws_instance" "k8s" {
  ami                         = var.ami_id
  instance_type               = var.k8s_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-k8s", Role = "k8s" }
}

E_O_F_ccf5a12a

# ---- terraform/main.tf ----
write "terraform/main.tf" <<'E_O_F_b89d1f9f'
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

E_O_F_b89d1f9f

# ---- terraform/outputs.tf ----
write "terraform/outputs.tf" <<'E_O_F_08a2ed30'
output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "SSH / UI (port 8080) of the Jenkins instance"
}

output "k8s_public_ip" {
  value       = aws_instance.k8s.public_ip
  description = "SSH / app NodePort / Grafana NodePort target"
}

output "s3_artifacts_bucket" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "Bucket name to store Jenkins build artifacts"
}

E_O_F_08a2ed30

# ---- terraform/s3.tf ----
write "terraform/s3.tf" <<'E_O_F_df93f928'
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = { Name = "${var.project}-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

E_O_F_df93f928

# ---- terraform/security_groups.tf ----
write "terraform/security_groups.tf" <<'E_O_F_8692434a'
resource "aws_security_group" "jenkins" {
  name        = "${var.project}-jenkins-sg"
  description = "SSH from my IP + Jenkins UI"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-jenkins-sg" }
}

resource "aws_security_group" "k8s" {
  name        = "${var.project}-k8s-sg"
  description = "SSH + app NodePort + Grafana NodePort"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Notes app NodePort
  ingress {
    description = "Notes app NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Grafana NodePort
  ingress {
    description = "Grafana NodePort"
    from_port   = 30030
    to_port     = 30030
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Prometheus NodePort (optional)
  ingress {
    description = "Prometheus NodePort"
    from_port   = 30090
    to_port     = 30090
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # k3s API (so Jenkins can talk to the cluster inside the VPC)
  ingress {
    description = "k3s API from Jenkins SG"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-k8s-sg" }
}

E_O_F_8692434a

# ---- terraform/terraform.tfvars.example ----
write "terraform/terraform.tfvars.example" <<'E_O_F_799ff019'
aws_region         = "us-east-1"
project            = "devops-notes"
my_ip_cidr         = "YOUR_IP/32"
ssh_public_key     = "ssh-ed25519 AAAA... your-key-contents-here"
jenkins_instance_type = "t3.small"
k8s_instance_type     = "t3.medium"
# ami_id is pinned in variables.tf; override here if you change region.

E_O_F_799ff019

# ---- terraform/variables.tf ----
write "terraform/variables.tf" <<'E_O_F_de972723'
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "project" {
  type        = string
  default     = "devops-notes"
  description = "Project name prefix for all resources"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form (e.g. 1.2.3.4/32) for SSH access"
}

variable "ssh_public_key" {
  type        = string
  description = "Contents of your SSH public key for EC2 access"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.small"
}

variable "k8s_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_id" {
  type        = string
  description = "Ubuntu 22.04 LTS AMI (us-east-1 default)."
  default     = "ami-0e86e20dae9224db8"
}

E_O_F_de972723

# ---- terraform/vpc.tf ----
write "terraform/vpc.tf" <<'E_O_F_3f88bd63'
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

E_O_F_3f88bd63

# Make scripts executable (if any added later)
chmod +x setup.sh 2>/dev/null || true

echo
echo ">>> Files written in: $(pwd)"
echo ">>> Initializing git repo..."

git init -b main
git add .
git commit -m "chore: initial devops notes practice project"
git remote add origin "$REMOTE_URL" 2>/dev/null || git remote set-url origin "$REMOTE_URL"

echo
echo ">>> Pushing to $REMOTE_URL (branch: main)"
echo ">>> If this fails on auth, run:  gh auth login  OR set up a PAT and retry 'git push -u origin main'"
git push -u origin main
