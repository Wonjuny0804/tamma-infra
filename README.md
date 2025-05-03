# Tamma Infra

This repository defines the **infrastructure-as-code (IaC)** for [Tamma](https://tamma.infuseailabs.com) — an AI-powered content assistant for creators, developed under **InfuseAI Labs**. The infrastructure uses **Terraform** on **AWS** and supports end-to-end audio and (future) video processing pipelines.

---

## 🌐 Architecture Overview

```text
User upload (via Next.js API)
    └──▶ S3 (raw bucket)
            └──▶ Upload completion triggers custom API ➔ SQS (jobs queue)
                    └──▶ Lambda invoker picks up job_id + s3_key
                            └──▶ ECS Fargate task (audio-clean / video pipelines)
                                    └──▶ Processed output saved to S3 (derived bucket)

User requests download (via Next.js API)
    └──▶ Presigned GET URL ➔ temporary, secure access to derived S3 objects
```

---

## 📦 Infrastructure Components

### 1. **VPC & Subnets**
- Private/public subnets across multiple AZs
- NAT Gateway for outbound internet access

### 2. **S3 Buckets**
- `tamma-dev-raw` — stores user-uploaded media
- `tamma-dev-derived` — stores processed assets
- Lifecycle rule: raw bucket objects expire after 30 days

### 3. **SQS Queues**
- `tamma-dev-jobs` — FIFO queue receives job messages (custom API sends `{job_id, s3_key}`)
- `tamma-dev-jobs-dlq` — dead-letter queue for failed messages

### 4. **Lambda Function**
- Function: **trigger-audio-clean**
- Invoked by SQS messages via an Event Source Mapping
- Reads `job_id` + `s3_key`, invokes ECS task with those parameters
- Environment variables include SSM‑backed Supabase URL & service key, bucket names, networking, etc.

### 5. **ECS (Fargate)**
- Cluster: `tamma-dev-cluster` with FARGATE and FARGATE_SPOT providers
- **AutoScalingGroup** (GPU-backed) for future video workloads
- Task definition `audio-clean` uses Docker image from ECR
- CloudWatch logs retention: 14 days

### 6. **ECR Repository**
- `tamma-dev-audio-clean` — stores the ffmpeg‑powered processing image
- Lifecycle policy: retain last 10 images

### 7. **IAM Roles & Users**
- **Lambda Invoker Role** — allows SQS reads, ECS RunTask, SSM parameter access
- **ECS Task Execution Role** — allows container pulls, S3 read/write, CloudWatch logs
- **`tamma-presign` User** — CLI/API user for front‑end; granted SQS SendMessage and S3 GetObject rights

### 8. **SSM Parameter Store**
- `/tamma/dev/supabase_url` (String)
- `/tamma/dev/supabase_service_key` (SecureString)

---

## 🧪 How to Deploy

### 🔧 Prerequisites:
- Terraform CLI >= 1.6
- AWS CLI configured with an IAM identity possessing Terraform apply rights
- `secret.auto.tfvars` (git‑ignored) with Supabase URL & service key

### 🚀 Deploy Commands:

```bash
# 1. Initialize Terraform
terraform init

# 2. Validate configuration
terraform validate

# 3. Apply the stack (builds layer, creates resources)
terraform apply
```

---

## 📁 File Structure

```
├── main.tf             # Terraform configuration
├── variables.tf        # Input variable declarations
├── lambda_layer/       # Python dependencies for the Lambda layer
│   ├── python/
│   └── requirements.txt
├── main.py             # Lambda function handler source
└── README.md           # This file
```

---

© 2025 InfuseAI Labs — Built for efficient content workflows.
