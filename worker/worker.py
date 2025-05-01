import boto3
import os

s3 = boto3.client("s3")

input_bucket = os.environ["RAW_BUCKET"]
output_bucket = os.environ["DERIVED_BUCKET"]
input_key = os.environ["INPUT_FILE"]

output_key = input_key.replace("audio/", "audio/cleaned_")

def process_file(temp_path):
    # TODO: fake processing for now - just copy it
    with open(temp_path, "rb") as f:
        data = f.read()
    return data


def main():
    local_path = "/tmp/input.mp3"

    # 1. Download
    s3.download_file(input_bucket, input_key, local_path)

    # 2. Process
    processed_data = process_file(local_path)

    # 3. Upload
    s3.put_object(Bucket=output_bucket, Key=output_key, Body=processed_data, ContentType="audio/mpeg")

    print(f"Uploaded file: s3://{output_bucket}/{output_key}")

if __name__ == "__main__":
    main()

