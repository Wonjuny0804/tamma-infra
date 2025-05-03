import boto3
import os
import tempfile
import subprocess
from supabase import Client, create_client



input_bucket = os.environ["RAW_BUCKET"]
output_bucket = os.environ["DERIVED_BUCKET"]
input_key = os.environ["INPUT_FILE"]

output_key = input_key.replace("audio/", "audio/cleaned_")

RAW_BUCKET      = os.environ["RAW_BUCKET"]
DERIVED_BUCKET  = os.environ["DERIVED_BUCKET"]
JOB_ID          = os.environ["JOB_ID"]
S3_KEY          = os.environ["INPUT_FILE"]

SUPABASE_URL  = os.environ["SUPABASE_URL"]
SUPABASE_KEY  = os.environ["SUPABASE_SERVICE_KEY"]

s3 = boto3.client("s3")
supabase = create_client(SUPABASE_URL, SUPABASE_KEY)


def download_to_tmp():
    tmp_in = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
    s3.download_file(RAW_BUCKET, S3_KEY, tmp_in.name)
    return tmp_in.name

def ffmpeg_clean(in_path):
    out_path = tempfile.NamedTemporaryFile(delete=False, suffix=".m4a").name

    cmd = [
        "ffmpeg", "-y", "-i", in_path,
        "-af", "afftdn,loudnorm=I=-16:LRA=11:TP=-1.5",
        "-c:a", "aac", "-b:a", "192k",
        out_path
    ]
    subprocess.run(cmd, check=True)
    return out_path

def upload_result(out_path):
    clean_key = S3_KEY.replace("audio/", "audio/cleaned_").replace(".wav", ".m4a")
    s3.upload_file(out_path, DERIVED_BUCKET, clean_key, ExtraArgs={
        "ContentType": "audio/mp4"
    })
    return clean_key

def mark_done(clean_key):
    supabase.table("jobs").update({
        "status": "done",
        "derived_key": clean_key
    }).eq("id", JOB_ID).execute()


if __name__ == "__main__":
    in_file   = download_to_tmp()
    out_file  = ffmpeg_clean(in_file)
    key       = upload_result(out_file)
    mark_done(key)
    print("✅ Job complete:", key)

