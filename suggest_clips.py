import os, json, boto3, re, urllib.parse
from supabase import create_client

s3 = boto3.client("s3")
supabase = create_client(os.environ["SUPABASE_URL"],
                         os.environ["SUPABASE_SERVICE_KEY"])

def pick_clips(segments):
    """Group ~30‑sec windows, take first ≤ 7 with most words."""
    clips, window, start = [], [], segments[0]["start"]
    for seg in segments:
        window.append(seg)
        if seg["end"] - start >= 30:
            text = " ".join(s["text"] for s in window)
            clips.append({
                "start":   round(start, 2),
                "end":     round(seg["end"], 2),
                "summary": re.sub(r"\s+", " ", text)[:120] + "…"
            })
            window, start = [], seg["end"]
        if len(clips) == 7:
            break
    return clips

def _process_object(bucket: str, key: str):
    print(f"S3 object: {bucket}/{key}")
    data   = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    clips  = pick_clips(data["segments"])
    print(f"pick_clips returned {len(clips)} items")

    res    = supabase.from_("jobs").select("id").eq("transcript_key", key).single().execute()
    job_id = res.data["id"]
    print(f"Mapped transcript_key → job_id: {job_id}")

    supabase.from_("jobs").update({
        "clips_json":   clips,
        "clips_status": "ready"
    }).eq("id", job_id).execute()

def lambda_handler(event, _ctx):
    # ⇢ direct S3 (old dev uploads)
    if "Records" in event:
        for rec in event["Records"]:
            _process_object(
                rec["s3"]["bucket"]["name"],
                urllib.parse.unquote(rec["s3"]["object"]["key"])
            )
    # ⇢ EventBridge (current prod path)
    elif event.get("source") == "aws.s3":
        _process_object(
            event["detail"]["bucket"]["name"],
            urllib.parse.unquote(event["detail"]["object"]["key"])
        )
    else:
        print("Unsupported event:", event.keys())

    return {"statusCode": 200}
