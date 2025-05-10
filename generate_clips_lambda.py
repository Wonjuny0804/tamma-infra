# generate_clips_lambda.py
import json, os, boto3, urllib.parse

ecs = boto3.client("ecs")
s3  = boto3.client("s3")

CLUSTER      = os.environ["ECS_CLUSTER_ARN"]
TASK_FAMILY  = os.environ["CLIP_TASK_FAMILY"]     # tamma-dev-video-clip
SUBNETS      = os.environ["PRIVATE_SUBNETS"].split(",")
SECURITY_GRP = os.environ["TASK_SG"]

def _launch_task(payload: dict):
    ecs.run_task(
        cluster        = CLUSTER,
        launchType     = "FARGATE",
        taskDefinition = TASK_FAMILY,
        count          = 1,
        networkConfiguration = {
            "awsvpcConfiguration": {
                "subnets": SUBNETS,
                "securityGroups": [SECURITY_GRP],
                "assignPublicIp": "DISABLED",
            }
        },
        overrides = {
            "containerOverrides": [{
                "name": "video-clip",
                "environment": [
                    { "name": "JOB_ID",         "value": str(payload["job_id"]) },
                    { "name": "CLIP_INDEXES",   "value": json.dumps(payload["indexes"]) },
                    { "name": "TRANSCRIPT_KEY", "value": payload["transcript_key"] },
                ]
            }]
        },
    )

def handler(event, _ctx):
    # 1) direct‑S3 shape (if ever used)
    if "Records" in event:
        for rec in event["Records"]:
            bucket = rec["s3"]["bucket"]["name"]
            key    = urllib.parse.unquote(rec["s3"]["object"]["key"])
            payload = json.loads(
                s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            )
            _launch_task(payload)

    # 2) EventBridge shape (current path)
    elif event.get("source") == "aws.s3":
        bucket = event["detail"]["bucket"]["name"]
        key    = urllib.parse.unquote(event["detail"]["object"]["key"])
        payload = json.loads(
            s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        )
        _launch_task(payload)

    else:
        print("Unsupported event format:", event.keys())
