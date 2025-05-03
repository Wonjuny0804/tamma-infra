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
        message_body = json.loads(record["body"])

        # Extract S3 event from SQS message
        s3_event = json.loads(message_body["Message"]) if "Message" in message_body else message_body

        for s3_record in s3_event["Records"]:
            bucket = s3_record["s3"]["bucket"]["name"]
            key = s3_record["s3"]["object"]["key"]

            row = supabase.from_("jobs").select("id").eq("s3_key", key).single().execute()
            job_id = row.data["id"]

            print(f"Launching ECS task for file: s3://{bucket}/{key}")

            ecs.run_task(
                cluster=os.environ["CLUSTER_NAME"],
                launchType="FARGATE",
                taskDefinition=os.environ["TASK_DEFINITION"],
                count=1,
                networkConfiguration={
                    "awsvpcConfiguration": {
                        "subnets": [os.environ["SUBNET_ID"]],
                        "securityGroups": [os.environ["SECURITY_GROUP_ID"]],
                        "assignPublicIp": "DISABLED"
                    }
                },
                overrides={
                    "containerOverrides": [
                        {
                            "name": "audio-clean",
                            "environment": [
                                {"name": "INPUT_FILE", "value": key},
                                {"name": "RAW_BUCKET", "value": bucket},
                                {"name": "DERIVED_BUCKET", "value": os.environ["DERIVED_BUCKET"]},
                                {"name": "JOBS_QUEUE_URL", "value": os.environ["JOBS_QUEUE_URL"]}
                            ]
                        }
                    ]
                }
            )

    return {"statusCode": 200, "body": "Triggered ECS task"}
