##########################
# TAMMA — Day 1 Skeleton (validated) #
##########################
# Fully self‑contained Terraform stack that validates on AWS provider 5.x.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

##############################
# 0.  GLOBAL  VARIABLES      #
##############################
variable "region" { default = "us-east-1" }
variable "project" { default = "tamma" }
variable "environment" { default = "dev" }

##############################
# 1. AWS  PROVIDER           #
##############################
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
    }
  }
}

data "aws_availability_zones" "available" {}

##############################
# 2. NETWORK — VPC & Subnets #
##############################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-${var.environment}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(0, 3) : "10.0.${i}.0/24"]
  public_subnets  = [for i in range(100, 103) : "10.0.${i}.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

##############################
# 3. STORAGE — S3 BUCKETS    #
##############################
resource "aws_s3_bucket" "raw" {
  bucket        = "${var.project}-${var.environment}-raw"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_expire" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "expire-raw"
    status = "Enabled"

    filter { prefix = "" }

    expiration { days = 30 }
  }
}

resource "aws_s3_bucket" "derived" {
  bucket        = "${var.project}-${var.environment}-derived"
  force_destroy = true
}

#################################
# 4. MESSAGING — SQS FIFO QUEUE #
#################################
resource "aws_sqs_queue" "jobs" {
  name                        = "${var.project}-${var.environment}-jobs.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 900
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn,
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "jobs_dlq" {
  name                        = "${var.project}-${var.environment}-jobs-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

##############################
# 5. COMPUTE — ECS CLUSTER   #
##############################
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "fargate" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

##################################################
# 5b. GPU AutoScalingGroup & Capacity Provider   #
##################################################
# Latest Amazon Linux 2 GPU‑optimized AMI

data "aws_ssm_parameter" "al2_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id"
}

module "gpu_asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 8.0"

  name             = "${var.project}-${var.environment}-gpu-asg"
  desired_capacity = 0
  min_size         = 0
  max_size         = 2

  instance_type       = "g5.xlarge"
  vpc_zone_identifier = module.vpc.private_subnets
  image_id            = data.aws_ssm_parameter.al2_gpu_ami.value

  enable_monitoring           = true
  create_iam_instance_profile = true
  iam_role_name               = "${var.project}-${var.environment}-gpu-role"
}

resource "aws_ecs_capacity_provider" "gpu_provider" {
  name = "${var.project}-${var.environment}-gpu-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn = module.gpu_asg.autoscaling_group_arn

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 90
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "attach_gpu" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.gpu_provider.name]
}

##############################
# 5c. IMAGE REPOSITORY - ECR #
##############################

resource "aws_ecr_repository" "audio_clean" {
  name = "${var.project}-${var.environment}-audio-clean"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "audio_clean" {
  repository = aws_ecr_repository.audio_clean.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1,
      description  = "retain last 10 images",
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 },
      action       = { type = "expire" }
    }]
  })
}

##############################
# 6. PARAMETER STORE SECRETS #
##############################
resource "aws_ssm_parameter" "assemblyai_api_key" {
  name  = "/${var.project}/${var.environment}/assemblyai_api_key"
  type  = "SecureString"
  value = "changeme"
}

resource "aws_ssm_parameter" "openai_api_key" {
  name  = "/${var.project}/${var.environment}/openai_api_key"
  type  = "SecureString"
  value = "changeme"
}

##############################
# 7. OUTPUTS                 #
##############################
output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.id
}
