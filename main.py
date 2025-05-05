import json
import boto3
import os
from supabase import create_client

ecs = boto3.client("ecs")

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

def lambda_handler(event, context):
    print("Event:", json.dumps(event))
    for record in event["Records"]:
        body   = json.loads(record["body"])
        job_id = body["job_id"]
        key    = body["s3_key"]
        bucket = os.environ["RAW_BUCKET"]
        file_type = "video" if key.lower().endswith((".mp4", ".mov")) else "audio"
        task_family = os.environ["VIDEO_TASK_DEF"] if file_type == "video" else os.environ["TASK_DEFINITION"]
        derived = os.environ["DERIVED_BUCKET"]

        print(f"Launching ECS task for job={job_id}, s3://{bucket}/{key}")

        ecs.run_task(
            cluster=os.environ["CLUSTER_NAME"],
            launchType="FARGATE",
            taskDefinition=task_family,
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets":         [os.environ["SUBNET_ID"]],
                    "securityGroups":  [os.environ["SECURITY_GROUP_ID"]],
                    "assignPublicIp": "DISABLED"
                }
            },
            overrides={
                "containerOverrides": [
                    {
                        "name": "audio-clean",
                        "environment": [
                            {"name": "JOB_ID",        "value": str(job_id)},
                            {"name": "INPUT_FILE",    "value": key},
                            {"name": "RAW_BUCKET",    "value": bucket},
                            {"name": "DERIVED_BUCKET","value": derived},
                        ]
                    }
                ]
            }
        )

    return {"statusCode": 200, "body": "Triggered ECS task"}