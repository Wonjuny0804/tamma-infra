############################################
#  -- START: video‑clip worker bundle --   #
############################################

# 1.  ECR repo
resource "aws_ecr_repository" "video_clip" {
  name = "${var.project}-${var.environment}-video-clip"
  image_scanning_configuration { scan_on_push = true }
}

# 2.  Log group
resource "aws_cloudwatch_log_group" "video_clip" {
  name              = "/ecs/video-clip"
  retention_in_days = 14
}

# 3.  ECS task definition (container name MUST be "video-clip")
resource "aws_ecs_task_definition" "video_clip_task" {
  family                   = "${var.project}-${var.environment}-video-clip"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "2048"
  memory                   = "4096"

  execution_role_arn = aws_iam_role.audio_clean_task_exec.arn
  task_role_arn      = aws_iam_role.audio_clean_task_exec.arn

  container_definitions = jsonencode([{
    name      = "video-clip",
    image     = "${aws_ecr_repository.video_clip.repository_url}:latest",
    essential = true,
    environment = [
      { "name" : "RAW_BUCKET", "value" : aws_s3_bucket.raw.bucket },
      { "name" : "DERIVED_BUCKET", "value" : aws_s3_bucket.derived.bucket },
      { "name" : "SUPABASE_URL", "value" : var.supabase_url },
      { "name" : "SUPABASE_SERVICE_KEY", "value" : var.supabase_service_key }
    ],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        awslogs-group         = aws_cloudwatch_log_group.video_clip.name,
        awslogs-region        = var.region,
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

# 4.  Package the Lambda code
data "archive_file" "generate_clips_zip" {
  type        = "zip"
  source_file = "${path.module}/generate_clips_lambda.py"
  output_path = "${path.module}/generate_clips.zip"
}

# 5.  Lambda that launches the task
resource "aws_lambda_function" "generate_clips" {
  function_name    = "${var.project}-${var.environment}-generate-clips"
  filename         = data.archive_file.generate_clips_zip.output_path
  source_code_hash = data.archive_file.generate_clips_zip.output_base64sha256
  handler          = "generate_clips_lambda.handler"
  runtime          = "python3.11"
  timeout          = 30
  role             = aws_iam_role.lambda_trigger_ecs_role.arn # reuse existing RunTask role

  environment {
    variables = {
      ECS_CLUSTER_ARN  = aws_ecs_cluster.main.arn
      CLIP_TASK_FAMILY = aws_ecs_task_definition.video_clip_task.family
      PRIVATE_SUBNETS  = join(",", module.vpc.private_subnets)
      TASK_SG          = aws_security_group.worker.id
    }
  }

  # if paused flag exists, throttle the function
  reserved_concurrent_executions = try(var.paused, false) ? 0 : -1
}


############################################
#  -- END: video‑clip worker bundle --     #
############################################
