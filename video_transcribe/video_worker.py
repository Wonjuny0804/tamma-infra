import os, json, tempfile, boto3
from supabase import create_client
import whisper

RAW_BUCKET     = os.environ["RAW_BUCKET"]
DERIVED_BUCKET = os.environ["DERIVED_BUCKET"]
JOB_ID         = os.environ["JOB_ID"]
INPUT_FILE     = os.environ["INPUT_FILE"]

s3        = boto3.client("s3")
supabase  = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
model     = whisper.load_model("base")   # CPU model (≈70 MB)

def main():
    # 1. Download the video from S3
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".mp4")
    s3.download_file(RAW_BUCKET, INPUT_FILE, tmp.name)

    # 2. Transcribe
    result = model.transcribe(tmp.name)
    result["video_key"] = INPUT_FILE  
    
    transcript_key = f"transcripts/{INPUT_FILE}.json"
    s3.put_object(Bucket=DERIVED_BUCKET,
                  Key=transcript_key,
                  Body=json.dumps(result),
                  ContentType="application/json")

    # 3. Update Supabase row
    supabase.from_("jobs").update({
        "transcript_key": transcript_key,
        "transcript_status": "done"
    }).eq("id", JOB_ID).execute()

if __name__ == "__main__":
    main()
