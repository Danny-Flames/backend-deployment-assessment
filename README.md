# Backend Deployment Assessment — MuchToDo

Infrastructure-as-code and containerisation for the **MuchToDo** Golang backend API.

Terraform provisions an AWS VPC with public and private subnets, a bastion host, a backend
server, a MongoDB server and an Application Load Balancer. Docker builds the Go
application into a lean multi-stage image, and Docker Compose runs it against MongoDB on
the backend instance.

**Author:** Daniel Ekpa Egwoke · AltSchool Africa Cloud Engineering · Baraka 2026 Cohort

---

## Contents

1. [Architecture](#architecture)
2. [Repository structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Setup](#setup)
5. [Step 1 — Build and run locally](#step-1--build-and-run-locally)
6. [Step 2 — Provision the infrastructure](#step-2--provision-the-infrastructure)
7. [Step 3 — Deploy to EC2](#step-3--deploy-to-ec2)
8. [Verification](#verification)
9. [Teardown and cleanup](#teardown-and-cleanup)
10. [Design notes](#design-notes)
11. [Evidence](#evidence)

---

## Architecture

```
                    ┌────────────────────────── AWS VPC 10.0.0.0/16 ───────────────────────────┐
                    │                                                                           │
   Internet         │   Public subnets (2 AZs)            Private subnets (2 AZs)               │
      │             │   ┌──────────────────────┐          ┌──────────────────────────┐          │
      │  :80        │   │  Application         │  :8080   │  Backend EC2             │          │
      ├─────────────┼──▶│  Load Balancer       │─────────▶│  Docker: API + MongoDB   │          │
      │             │   └──────────────────────┘          └───────────┬──────────────┘          │
      │             │   ┌──────────────────────┐                      │ :27017                  │
      │  :22        │   │  Bastion host        │  :22                 ▼                         │
      └─────────────┼──▶│  (Elastic IP)        │─────────▶┌──────────────────────────┐          │
       operator IP  │   └──────────────────────┘          │  MongoDB EC2             │          │
                    │   ┌──────────────────────┐          └──────────────────────────┘          │
                    │   │  NAT Gateway         │◀──── outbound only ─────────────────            │
                    │   └──────────┬───────────┘                                                 │
                    └──────────────┼─────────────────────────────────────────────────────────────┘
                                   │
                            Internet Gateway
```

**Security group rules (least privilege):**

| Security group | Port | Source |
|---|---|---|
| `startuptech-alb-sg` | 80, 443 | `0.0.0.0/0` |
| `startuptech-bastion-sg` | 22 | operator IP only (`var.my_ip_cidr`) |
| `startuptech-backend-sg` | 8080 | ALB security group only |
| `startuptech-backend-sg` | 22 | bastion security group only |
| `startuptech-mongodb-sg` | 27017 | backend security group only |
| `startuptech-mongodb-sg` | 22 | bastion security group only |

Neither private instance has a public IP. Outbound access for `yum`, Docker Hub and
GitHub routes through the NAT Gateway. The database port is reachable only from the
backend tier, referenced by security group ID rather than by CIDR.

---

## Repository structure

```
backend-deployment-assessment/
├── terraform/
│   ├── main.tf                      # VPC, subnets, gateways, SGs, EC2, ALB
│   ├── variables.tf                 # Input variables with descriptions and defaults
│   ├── outputs.tf                   # VPC ID, ALB DNS, bastion IP, backend private IP
│   ├── terraform.tfvars.example     # Example values — no secrets
│   ├── terraform.tfstate            # Submitted as required
│   └── user_data/
│       ├── backend_setup.sh         # Installs Docker + Docker Compose v2
│       └── mongodb_setup.sh         # Installs and starts MongoDB 8.0
├── much-to-do/                      # Git submodule — the application source
├── Dockerfile                       # Multi-stage build, non-root user, HEALTHCHECK
├── docker-compose.yml               # Backend + MongoDB services
├── .dockerignore
├── .env.example
├── evidence/                        # Deployment screenshots and plan output
└── README.md
```

---

## Prerequisites

| Tool | Version | Used for |
|---|---|---|
| Terraform | >= 1.6 | Provisioning AWS infrastructure |
| AWS CLI | v2 | Credentials for the Terraform provider |
| Docker Engine | >= 24 | Building and running the image |
| Docker Compose | v2 (`docker compose`) | Orchestrating backend + MongoDB |
| Git | any recent | Cloning, including submodules |
| An AWS account | — | Permission to create VPC, EC2, ELB and EIP resources |
| An SSH key pair | — | `ssh-keygen -t ed25519 -f ~/.ssh/altschool_assessment_1 -N ""` |

Configure AWS credentials before running Terraform:

```bash
aws configure
aws sts get-caller-identity     # confirms the credentials work
```

> **Cost.** The NAT Gateway (~$0.045/hour) and the ALB (~$0.0225/hour) bill continuously
> and are **not** free-tier eligible. Expect roughly **$1.70 per day** for the whole
> stack. Run `terraform destroy` as soon as the deployment has been verified.

---

## Setup

Clone the repository **with the application submodule**:

```bash
git clone --recurse-submodules https://github.com/Danny-Flames/backend-deployment-assessment.git
cd backend-deployment-assessment
```

> If cloned without `--recurse-submodules`, the `much-to-do/` directory will be empty and
> the Docker build will fail with `"/much-to-do/Server/MuchToDo": not found`. Fix with:
>
> ```bash
> git submodule update --init --recursive
> ```

---

## Step 1 — Build and run locally

Verify the application works before provisioning any paid infrastructure.

```bash
cp .env.example .env
```

Edit `.env` and set a real signing key:

```bash
openssl rand -base64 48        # paste the output as JWT_SECRET_KEY
```

Build the image:

```bash
docker compose build --no-cache
```

The multi-stage build compiles a statically linked binary in a `golang:1.25-alpine`
builder, then copies only that binary into an `alpine:3.22` runtime image — no compiler,
no module cache, no source code in the final image.

Start the stack:

```bash
docker compose up -d
docker compose ps
```

MongoDB's health check has a 90-second start period, so the backend deliberately waits
before starting. Both services should report `Up`, with `mongodb` marked `(healthy)`.

Confirm the API:

```bash
curl -i http://localhost:8080/health
```

Expected:

```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"cache":"disabled","database":"ok"}
```

`"database":"ok"` confirms the API reached MongoDB, not merely that something answered on
port 8080.

Stop the local stack when finished:

```bash
docker compose down
```

---

## Step 2 — Provision the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Set the two values that have no default.

**`my_ip_cidr`** — your current public address, the only source permitted to SSH into the
bastion:

```bash
curl -s https://checkip.amazonaws.com
```

Append `/32`, e.g. `"102.88.112.70/32"`.

**`ssh_public_key`** — the public half of your SSH key pair:

```bash
cat ~/.ssh/altschool_assessment_1.pub
```

Copy the entire single line. Only the `.pub` file — the private key never enters
Terraform, state or git.

Then provision:

```bash
terraform fmt -check
terraform init
terraform validate
terraform plan
terraform apply
```

`apply` takes 4–5 minutes, mostly waiting on the NAT Gateway and the ALB, and creates
**38 resources**. On completion Terraform prints:

```
vpc_id                 = "vpc-0462ae32e9e465291"
alb_dns_name           = "startuptech-alb-2144315610.us-east-1.elb.amazonaws.com"
bastion_public_ip      = "100.62.248.171"
backend_private_ip     = "10.0.11.153"
mongodb_private_ip     = "10.0.12.185"
ssh_to_backend_command = "ssh -J ec2-user@100.62.248.171 ec2-user@10.0.11.153"
health_check_url       = "http://startuptech-alb-....elb.amazonaws.com/health"
```

Read any single value later with:

```bash
terraform output -raw alb_dns_name
```

The ALB target group will report **unhealthy** until Step 3 completes. That is expected —
nothing is listening on port 8080 yet.

---

## Step 3 — Deploy to EC2

### 3.1 Connect through the bastion

The backend instance has no public IP, so all access jumps through the bastion. Add this
to `~/.ssh/config`, substituting the addresses from the Terraform outputs:

```
Host altschool-bastion
    HostName <bastion_public_ip>
    User ec2-user
    IdentityFile ~/.ssh/altschool_assessment_1

Host altschool-backend
    HostName <backend_private_ip>
    User ec2-user
    IdentityFile ~/.ssh/altschool_assessment_1
    ProxyJump altschool-bastion
```

Then:

```bash
chmod 600 ~/.ssh/config
ssh altschool-backend
```

`IdentityFile` must be set per host: OpenSSH applies command-line options such as `-i` to
the destination host only, so a jump host receives no identity and the connection fails at
the bastion.

### 3.2 Confirm the bootstrap completed

`user_data` installs Docker and Docker Compose on first boot:

```bash
ls -l /var/log/backend-setup-complete    # exists once the script succeeded
docker --version
docker compose version
sudo tail -40 /var/log/user-data.log     # full bootstrap log
```

If `docker` reports a permission error, log out and back in — group membership applies
only to new sessions.

### 3.3 Prepare the instance

`t3.micro` provides 1 GiB of RAM (~940 MB usable), which is tight for MongoDB, the API and
the Docker daemon together. Add swap before starting the stack:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

Check disk headroom — the root volume is 8 GB and the `mongo:8.0` image alone is 943 MB:

```bash
df -h /
docker builder prune -af     # if usage exceeds ~85%
```

### 3.4 Deploy the application

```bash
git clone --recurse-submodules https://github.com/Danny-Flames/backend-deployment-assessment.git
cd backend-deployment-assessment
cp .env.example .env
nano .env                    
```

Transfer the image built in Step 1 rather than compiling on the instance. **From your own
machine**, in the repository folder:

```bash
docker save muchtodo-backend:latest -o muchtodo-backend.tar
scp muchtodo-backend.tar altschool-backend:~/
```

`scp` picks up `ProxyJump` from `~/.ssh/config`, so it routes through the bastion
automatically.

**On the instance:**

```bash
docker load -i ~/muchtodo-backend.tar
rm ~/muchtodo-backend.tar
docker compose up -d
```

Compiling the Go application requires more memory than a 1 GiB instance can provide, so
the image is built once and shipped as an artefact — which is also how production
deployments work: CI builds the image, the server pulls it, and the deployment target
never runs a compiler. See [Design notes](#design-notes).

Confirm on the instance:

```bash
docker compose ps
curl -s http://localhost:8080/health
```

---

## Verification

**From the backend instance:**

```bash
docker compose ps                        # both Up, mongodb (healthy)
curl -s http://localhost:8080/health     # {"cache":"disabled","database":"ok"}
docker compose logs --tail 20 backend    # structured JSON logs
```

**Through the load balancer**, from your own machine. Target registration takes 30–60
seconds after the container starts:

```bash
curl -i "http://$(cd terraform && terraform output -raw alb_dns_name)/health"
```

**In the AWS Console:** EC2 → Target Groups → `startuptech-backend-tg` → **Targets**. The
backend instance should show **healthy**.

The backend logs will show requests from `ELB-HealthChecker/2.0` arriving from both
availability zones, confirming the full path works end to end.

---

## Teardown and cleanup

Destroy all AWS resources once the deployment has been verified:

```bash
cd terraform
terraform destroy
```

Type `yes` when prompted. Destruction takes 3–5 minutes.

Then confirm nothing remains in the AWS Console:

| Check | Expected |
|---|---|
| EC2 → Instances | all three terminated |
| EC2 → Elastic IPs | none allocated — unattached EIPs are billed |
| EC2 → Load Balancers | deleted |
| VPC → NAT Gateways | deleted |
| VPC → Your VPCs | `startuptech-vpc` removed |

Local cleanup:

```bash
docker compose down -v                     
docker image rm muchtodo-backend:latest
rm -f muchtodo-backend.tar
```

> `terraform destroy` empties `terraform.tfstate`. Commit the state file **before**
> destroying if it is required as a deliverable.

---

## Design notes

**MongoDB runs as a single-node replica set.**
`internal/handlers/user.go` uses `StartSession()` and `WithTransaction()` for the
delete-user flow, and MongoDB permits multi-document transactions only on a replica set or
a sharded cluster. Against a standalone `mongod` the application starts cleanly and
`/health` returns 200, so the failure would surface later as
`Transaction numbers are only allowed on a replica set member or mongos`.

**MongoDB is tuned for a 1 GiB host.**
`docker-compose.yml` caps WiredTiger at 256 MB (`--wiredTigerCacheSizeGB 0.25`) and runs
the health check once a minute. Left at its default, WiredTiger claims the larger of
256 MB or half of (RAM − 1 GB), and the health check invokes `mongosh`, a full Node.js
runtime costing 100–200 MB per run. On `t3.micro` those defaults exhaust memory and drive
the instance into swap. `condition: service_healthy` still gates the backend, so the
dependency guarantee is unchanged — only the intervals and cache ceiling are tuned.

**A placeholder `.env` is baked into the image.**
`internal/config/config.go` loads configuration with viper's `AutomaticEnv()` followed by
`Unmarshal()`. `Unmarshal` only populates keys viper already knows about, and the
application registers defaults for just `PORT`, `ENABLE_CACHE` and
`JWT_EXPIRATION_HOURS`. Keys such as `MONGO_URI` and `DB_NAME` are not registered, so
supplying them purely as container environment variables risks unmarshalling as empty
strings. The placeholder registers every key; Compose then supplies real values through
`environment:`, which viper ranks above config-file values.

**Private instances declare an explicit dependency on the NAT Gateway.**
`aws_instance.backend` and `aws_instance.mongodb` carry
`depends_on = [aws_nat_gateway.main, aws_route_table_association.private]`. Nothing in
their arguments references the route table, so Terraform cannot infer the ordering and is
free to create the instances in parallel with the NAT Gateway. cloud-init then runs
`user_data` within about a minute of boot, hits `yum update` with no outbound route, and
`set -euxo pipefail` aborts the bootstrap silently.

**Security group rules are standalone resources.**
`aws_vpc_security_group_ingress_rule` and `aws_vpc_security_group_egress_rule` are used
instead of inline blocks. The ALB needs egress to the backend group and the backend needs
ingress from the ALB; expressed inline that is a dependency cycle Terraform cannot
resolve.

**The Dockerfile lives in this repository rather than the application repository.**
The required file structure places it here. In production a Dockerfile belongs beside the
code it builds, CI publishes a tagged image to a registry such as ECR, and the server
pulls that image — removing the build toolchain, the source code and the build time from
the production host. The application is included here as a git submodule so an exact
commit is pinned without copying upstream source into this repository.

---

## Evidence

Deployment screenshots and the full Terraform plan output are in [`evidence/`](./evidence).

| # | File | Shows |
|---|---|---|
| 1 | `01-terraform-init.png` | Successful initialisation and provider download |
| 2 | `02a`–`02e-terraform-plan*.png`, `terraform-plan.txt` | Full plan output, 38 resources to create |
| 3 | `03-terraform-apply-complete.png` | `Apply complete!` with resource count and outputs |
| 4 | `04a-vpc-list.png`, `04b`/`04c-vpc-details.png` | VPC with correct CIDR and Name tag |
| 5 | `05-subnets-across-two-azs.png` | All four subnets across two availability zones |
| 6 | `06a`/`06b-security-groups-list.png`, `06c`/`06d-backend-sg-inbound-rules.png`, `06e`–`06g-mongodb-sg-inbound-rules.png` | Security groups and their inbound rules |
| 7 | `07-ec2-instances-running.png` | Bastion, backend and MongoDB instances running |
| 8 | `08a-alb-active.png`, `08b`–`08d-alb-*.png`, `08e`–`08g-target-group-*.png` | ALB active, target group with a healthy target |
| 9 | `09a-docker-build-start.png` → `09d-docker-build-complete.png` | Multi-stage build completing |
| 10 | `10-compose-local.png` | Both containers running locally |
| 11 | `11-health-local.png` | 200 response from `localhost:8080/health` |
| 12 | `12a`–`12c-ssh-via-bastion.png` | SSH jump: local → bastion → backend |
| 13 | `13a-compose-on-ec2.png`, `13b`/`13c-...-logs.png` | Both containers running on the backend instance |
| 14 | `14-alb-response.png` | Response via the ALB DNS name |
