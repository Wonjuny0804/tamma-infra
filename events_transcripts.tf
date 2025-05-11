##############################
#  transcripts/  → suggest_clips
##############################
resource "aws_cloudwatch_event_rule" "transcripts" {
  name  = "${var.project}-${var.environment}-transcripts"
  state = try(var.paused, false) ? "DISABLED" : "ENABLED"

  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created"],
    "detail" : {
      "bucket" : { "name" : [aws_s3_bucket.derived.bucket] },
      "object" : {
        "key" : [
          { "prefix" : "transcripts/" },
          { "suffix" : ".json" }
        ]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "transcripts_lambda" {
  rule      = aws_cloudwatch_event_rule.transcripts.name
  target_id = "SuggestClipsLambda"
  arn       = aws_lambda_function.suggest_clips.arn
}

resource "aws_lambda_permission" "allow_eventbridge_suggest_clips" {
  statement_id  = "AllowExecFromEventBridgeSuggestClips"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.suggest_clips.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.transcripts.arn
}
