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

resource "aws_s3_bucket_notification" "raw_to_jobs" {
  bucket = aws_s3_bucket.raw.id

  queue {
    queue_arn     = aws_sqs_queue.jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "audio/"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3_to_jobs]
}

#################################
# 4. MESSAGING — SQS FIFO QUEUE #
#################################
resource "aws_sqs_queue" "jobs" {
  name                       = "${var.project}-${var.environment}-jobs"
  fifo_queue                 = false
  visibility_timeout_seconds = 900
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn,
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "jobs_dlq" {
  name = "${var.project}-${var.environment}-jobs-dlq"
}

resource "aws_sqs_queue_policy" "allow_s3_to_jobs" {
  queue_url = aws_sqs_queue.jobs.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = "*",
      Action    = "sqs:SendMessage",
      Resource  = aws_sqs_queue.jobs.arn,
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_s3_bucket.raw.arn
        }
      }
    }]
  })
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
# 5d. ECS TASK EXECUTION ROLE #
##############################

resource "aws_iam_role" "audio_clean_task_exec" {
  name = "${var.project}-${var.environment}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "sts:AssumeRole",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_attach" {
  role       = aws_iam_role.audio_clean_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_access_s3" {
  name = "ecs-task-s3-access"
  role = aws_iam_role.audio_clean_task_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:HeadObject"
        ],
        Resource = [
          "${aws_s3_bucket.raw.arn}",
          "${aws_s3_bucket.raw.arn}/*",
          "${aws_s3_bucket.derived.arn}",
          "${aws_s3_bucket.derived.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_ssm_read" {
  name = "ecs-task-ssm-read"
  role = aws_iam_role.audio_clean_task_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["ssm:GetParameter"],
        Resource = [
          aws_ssm_parameter.supabase_url.arn,
          aws_ssm_parameter.supabase_service_key.arn
        ]
      }
    ]
  })
}


##############################
# 5e. ECS TASK DEFINITION    #
##############################

resource "aws_cloudwatch_log_group" "audio_clean" {
  name              = "/ecs/audio-clean"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "audio_clean_task" {
  family                   = "${var.project}-${var.environment}-audio-clean"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.audio_clean_task_exec.arn
  task_role_arn            = aws_iam_role.audio_clean_task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "audio-clean"
      image     = "${aws_ecr_repository.audio_clean.repository_url}:latest"
      essential = true
      environment = [
        {
          name  = "RAW_BUCKET"
          value = aws_s3_bucket.raw.bucket
        },
        {
          name  = "DERIVED_BUCKET"
          value = aws_s3_bucket.derived.bucket
        },
        {
          name  = "JOBS_QUEUE_URL"
          value = aws_sqs_queue.jobs.id
        },
        {
          name  = "SUPABASE_URL"
          value = aws_ssm_parameter.supabase_url.value
        },
        {
          name  = "SUPABASE_SERVICE_KEY"
          value = aws_ssm_parameter.supabase_service_key.value
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.audio_clean.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

##############################
# 5f. ECS SERVICE (optional) #
##############################

resource "aws_security_group" "worker" {
  name        = "${var.project}-${var.environment}-worker-sg"
  description = "Security group for ECS Fargate worker"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "audio_clean_service" {
  name            = "${var.project}-${var.environment}-audio-clean"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.audio_clean_task.arn
  launch_type     = "FARGATE"
  desired_count   = 0 # We'll run it manually for now

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  depends_on = [aws_ecs_cluster_capacity_providers.fargate]
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

resource "aws_ssm_parameter" "supabase_url" {
  name  = "/${var.project}/${var.environment}/supabase_url"
  type  = "String"
  value = "https://<your‑project>.supabase.co"
}

resource "aws_ssm_parameter" "supabase_service_key" {
  name  = "/${var.project}/${var.environment}/supabase_service_key"
  type  = "SecureString"
  value = "YOUR_SUPABASE_SERVICE_ROLE_KEY"
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

##############################
# 8. LAMBDA — SQS Trigger to ECS
##############################

resource "aws_iam_role" "lambda_trigger_ecs_role" {
  name = "${var.project}-${var.environment}-lambda-trigger-ecs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_trigger_ecs_policy" {
  name = "lambda-run-ecs-task"
  role = aws_iam_role.lambda_trigger_ecs_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecs:RunTask",
          "iam:PassRole"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ],
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      },
      {
        "Effect" : "Allow",
        "Action" : ["ssm:GetParameter"],
        "Resource" : [
          "${aws_ssm_parameter.supabase_url.arn}",
          "${aws_ssm_parameter.supabase_service_key.arn}"
        ]
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/main.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "trigger_audio_clean" {
  function_name = "${var.project}-${var.environment}-trigger-clean"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_trigger_ecs_role.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.11"
  timeout          = 30

  environment {
    variables = {
      CLUSTER_NAME         = aws_ecs_cluster.main.name
      TASK_DEFINITION      = aws_ecs_task_definition.audio_clean_task.family
      SUBNET_ID            = module.vpc.private_subnets[0]
      SECURITY_GROUP_ID    = aws_security_group.worker.id
      DERIVED_BUCKET       = aws_s3_bucket.derived.bucket
      JOBS_QUEUE_URL       = aws_sqs_queue.jobs.id
      SUPABASE_URL         = aws_ssm_parameter.supabase_url.value
      SUPABASE_SERVICE_KEY = aws_ssm_parameter.supabase_service_key.value
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.jobs.arn
  function_name    = aws_lambda_function.trigger_audio_clean.arn
  batch_size       = 1
}
