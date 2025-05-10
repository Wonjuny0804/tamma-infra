"""
clip_worker.py  – runs in ECS Fargate

Env‑vars injected by the Lambda trigger
--------------------------------------
RAW_BUCKET, DERIVED_BUCKET
SUPABASE_URL, SUPABASE_SERVICE_KEY
JOB_ID, CLIP_INDEXES (JSON array str), TRANSCRIPT_KEY
"""

import json, os, tempfile, subprocess, logging
from pathlib import Path
from typing import List

import boto3
from supabase import create_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)

RAW_BUCKET      = os.environ["RAW_BUCKET"]
DERIVED_BUCKET  = os.environ["DERIVED_BUCKET"]
JOB_ID          = os.environ["JOB_ID"]
CLIP_INDEXES    = json.loads(os.environ["CLIP_INDEXES"])
TRANSCRIPT_KEY  = os.environ["TRANSCRIPT_KEY"]

supabase = create_client(
    os.environ["SUPABASE_URL"],
    os.environ["SUPABASE_SERVICE_KEY"],
)
s3 = boto3.client("s3")


# ───────────────────────── helpers ──────────────────────────
def load_transcript() -> dict:
    obj = s3.get_object(Bucket=DERIVED_BUCKET, Key=TRANSCRIPT_KEY)
    return json.loads(obj["Body"].read())


def download_source(video_key: str) -> Path:
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".mp4")
    s3.download_file(Bucket=RAW_BUCKET, Key=video_key, Filename=tmp.name)
    return Path(tmp.name)


def cut_clip(src: Path, start: float, end: float, idx: int) -> Path:
    """Cuts inclusive start → exclusive end (seconds)"""
    out_tmp = tempfile.NamedTemporaryFile(delete=False, suffix=f"_{idx}.mp4")
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start:.3f}",
        "-to", f"{end:.3f}",
        "-i", str(src),
        "-c:v", "libx264", "-preset", "veryfast",
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        out_tmp.name,
    ]
    subprocess.run(cmd, check=True)
    return Path(out_tmp.name)


def upload_clip(local_path: Path, idx: int) -> str:
    s3_key = f"clips/{JOB_ID}/{idx}.mp4"
    s3.upload_file(str(local_path), DERIVED_BUCKET, s3_key)
    local_path.unlink(missing_ok=True)
    return s3_key


# ───────────────────────── main ──────────────────────────
def main() -> None:
    logging.info("Job %s – generating clips for indexes %s", JOB_ID, CLIP_INDEXES)

    transcript = load_transcript()
    segments: List[dict] = transcript["segments"]

    video_key = transcript.get("video_key") or transcript.get("source_key")
    if not video_key:
        raise RuntimeError("Transcript JSON missing 'video_key' / 'source_key'.")

    src_file = download_source(video_key)
    logging.info("Downloaded source video to %s", src_file)

    clip_keys: List[str] = []

    for idx in CLIP_INDEXES:
        try:
            segment = segments[idx]
            start, end = float(segment["start"]), float(segment["end"])
            if end <= start:
                logging.warning("Segment %s has non‑positive duration, skipping.", idx)
                continue
        except (IndexError, KeyError, ValueError) as exc:
            logging.warning("Bad segment data for index %s → %s, skipping.", idx, exc)
            continue

        try:
            local_clip = cut_clip(src_file, start, end, idx)
            s3_key = upload_clip(local_clip, idx)
            clip_keys.append(s3_key)
            logging.info("✔︎ Clip %s uploaded to s3://%s/%s", idx, DERIVED_BUCKET, s3_key)
        except subprocess.CalledProcessError as exc:
            logging.error("FFmpeg failed for index %s → %s", idx, exc)

    # clean local source
    src_file.unlink(missing_ok=True)

    supabase.from_("jobs").update(
        {"clips_keys": clip_keys, "clips_status": "generated"}
    ).eq("id", JOB_ID).execute()

    logging.info("Job %s done – %s clips generated.", JOB_ID, len(clip_keys))


if __name__ == "__main__":
    main()