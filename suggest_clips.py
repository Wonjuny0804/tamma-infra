import os, json, boto3, re
from supabase import create_client

s3 = boto3.client("s3")
supabase = create_client(os.environ["SUPABASE_URL"],
                         os.environ["SUPABASE_SERVICE_KEY"])

def pick_clips(segments):
    """
    Naive algorithm:
      group sentences into ~30‑sec windows,
      pick first 5 windows with highest word‑count.
    """
    clips = []
    window, start = [], segments[0]["start"]
    for seg in segments:
        window.append(seg)
        duration = seg["end"] - start
        if duration >= 30:
            text = " ".join(s["text"] for s in window)
            clips.append({
                "start": round(start, 2),
                "end":   round(seg["end"], 2),
                "summary": re.sub(r'\\s+', ' ', text)[:120] + "…"
            })
            window = []
            start  = seg["end"]
        if len(clips) == 7:
            break
    return clips

def lambda_handler(event, context):
    for rec in event["Records"]:
        bucket = rec["s3"]["bucket"]["name"]
        key    = rec["s3"]["object"]["key"] 
        print(f"S3 trigger for key: {key}")

        obj  = s3.get_object(Bucket=bucket, Key=key)
        data = json.loads(obj["Body"].read())
        clips = pick_clips(data["segments"])
        print(f"pick_clips returned {len(clips)} items")

        try:
            res = supabase.from_("jobs") \
                .select("id") \
                .eq("transcript_key", key) \
                .single() \
                .execute()
            job_id = res.data["id"]
            print(f"Mapped transcript_key → job_id: {job_id}")

            upd = supabase.from_("jobs") \
                .update({
                  "clips_json": clips,
                  "clips_status": "ready"
                }) \
                .eq("id", job_id) \
                .execute()
        except Exception as e:
            print(f"Error processing record: {e}")

    return {"statusCode": 200}
