# Tamma Infra

This repository defines the **infrastructure-as-code (IaC)** for [Tamma](https://tamma.infuseailabs.com) — an AI-powered content assistant for creators, developed as part of **InfuseAI Labs**. The infrastructure is built entirely using **Terraform**, provisioned on **AWS**, and designed to support both audio and video automation pipelines.

---

## 🌐 Architecture Overview

```
User Upload (S3)
    └──▶ S3 Event → SQS (jobs.fifo)
            └──▶ Lambda Trigger
                    └──▶ ECS Task (audio-clean or video-repurpose)
                            └──▶ Result saved to S3 (derived bucket)
```

---

## 📦 Infrastructure Components

### 1. **VPC + Subnets**
- Isolated private/public subnet layout
- NAT Gateway for outbound internet access

### 2. **S3 Buckets**
- `tamma-dev-raw` — for user uploads (audio/video)
- `tamma-dev-derived` — for AI-processed outputs
- Lifecycle rules clean up raw files after 30 days

### 3. **SQS Queues**
- `jobs.fifo` — receives file event messages from S3
- `jobs-dlq.fifo` — dead-letter queue for failed jobs

### 4. **Lambda Function**
- Triggered by new messages in `jobs` queue
- Invokes Fargate ECS task with correct parameters
- Defined in `main.py`, zipped and deployed via `archive_file`

### 5. **ECS (Fargate)**
- Cluster: `tamma-dev-cluster`
- GPU AutoScalingGroup (optional for future video models)
- Task: `audio-clean` (defined with IAM + CloudWatch logs)
- Pulls Docker image from ECR and runs `worker.py`

### 6. **ECR Repository**
- `tamma-dev-audio-clean` — holds the processing image

### 7. **IAM Roles**
- ECS Task Role — allows access to S3, logs, and execution
- Lambda Execution Role — allows `ecs:RunTask`, `sqs:ReceiveMessage`

---

## 🧪 How to Deploy

### 🔧 Prerequisites:
- Terraform CLI >= 1.6
- AWS CLI configured with an IAM user that has full permissions

### 🚀 Deploy Commands:

```bash
# Initialize Terraform
terraform init

# Validate config
terraform validate

# Apply the stack (takes 3–5 min)
terraform apply
```

---

## 📁 File Structure

```
├── main.tf                # All Terraform config
├── main.py                # Lambda source code
├── lambda.zip             # Auto-generated Lambda zip
├── README.md              # This file
```

---

## 🧠 Credits

This system was hand-built by a solo engineer from scratch using raw AWS services + Terraform. The purpose was to learn real-world production infra while solving a practical workflow pain point for creators.

> If you’re building something similar — fork this, ask questions, or just say hi!

---

© 2025 InfuseAI Labs — Built with purpose and automation.
