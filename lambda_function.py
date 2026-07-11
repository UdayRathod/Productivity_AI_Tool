"""
Brain Dump -> Plan  |  AWS Lambda backend

Takes a messy, stream-of-consciousness "brain dump" of things on your mind and
uses Amazon Bedrock (Nova Lite) to turn it into a clean, prioritized action plan.

Designed to run behind a Lambda Function URL (no API Gateway needed).
Runtime: Python 3.12  |  boto3 is bundled in the Lambda runtime.
"""

import json
import os
import re

import boto3
from botocore.config import Config

# Cross-region inference profile ID for Nova Lite. Override via env var if you
# use a different Nova model (e.g. us.amazon.nova-micro-v1:0 for cheaper/faster,
# or us.amazon.nova-pro-v1:0 for higher quality).
MODEL_ID = os.environ.get("MODEL_ID", "us.amazon.nova-lite-v1:0")
REGION = os.environ.get("BEDROCK_REGION", os.environ.get("AWS_REGION", "us-east-1"))

# Reuse the client across warm invocations. Give Bedrock a generous read timeout.
_bedrock = boto3.client(
    "bedrock-runtime",
    region_name=REGION,
    config=Config(read_timeout=60, retries={"max_attempts": 2}),
)

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
}

SYSTEM_PROMPT = """You are a sharp, practical productivity coach.

The user will give you a messy "brain dump": a stream of consciousness listing
everything on their mind — tasks, worries, errands, ideas, all jumbled together.

Your job: turn that chaos into a clear, prioritized action plan.

For every actionable item you find, score it:
- urgency  (1-5): how time-sensitive is it? (5 = must happen today/now)
- impact   (1-5): how much does doing it matter? (5 = high consequence)
Then priority_score = urgency * impact  (1-25).

Group each task into ONE category such as: Work, Health, Family, Finance,
Errands, Personal, Admin, Learning. Infer sensible categories from context.

Give a realistic time_estimate as a short human string ("15 min", "1 hr", "2 days").
Write a one-sentence reasoning for the priority.

Also pick the single best "do_first" task title, and write a short encouraging
"summary" (1-2 sentences) of what the plan looks like overall.

Respond with ONLY a valid JSON object, no markdown, no commentary, in EXACTLY this shape:
{
  "summary": "string",
  "do_first": "exact title of the top task",
  "tasks": [
    {
      "title": "string",
      "category": "string",
      "urgency": 1-5,
      "impact": 1-5,
      "priority_score": 1-25,
      "time_estimate": "string",
      "reasoning": "string"
    }
  ]
}
Order tasks from highest priority_score to lowest."""


def _extract_json(text):
    """Pull the first JSON object out of the model's text, tolerating stray
    markdown fences or leading/trailing prose."""
    text = text.strip()
    # Strip ```json ... ``` fences if present.
    fenced = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    # Otherwise grab from the first { to the last }.
    if not text.startswith("{"):
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1:
            text = text[start : end + 1]
    return json.loads(text)


def _response(status, body):
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }


def handler(event, context):
    # Function URL preflight (also handled by the URL's own CORS config, but safe).
    method = (
        event.get("requestContext", {}).get("http", {}).get("method", "POST")
    )
    if method == "OPTIONS":
        return _response(200, {"ok": True})

    # Parse the incoming brain dump.
    try:
        raw = event.get("body") or "{}"
        payload = json.loads(raw)
        brain_dump = (payload.get("brain_dump") or "").strip()
    except (ValueError, AttributeError):
        return _response(400, {"error": "Invalid JSON body."})

    if not brain_dump:
        return _response(400, {"error": "Please include a non-empty 'brain_dump'."})

    if len(brain_dump) > 6000:
        brain_dump = brain_dump[:6000]

    # Call Bedrock Nova via the Converse API.
    try:
        resp = _bedrock.converse(
            modelId=MODEL_ID,
            system=[{"text": SYSTEM_PROMPT}],
            messages=[{"role": "user", "content": [{"text": brain_dump}]}],
            inferenceConfig={"maxTokens": 2000, "temperature": 0.3, "topP": 0.9},
        )
        model_text = resp["output"]["message"]["content"][0]["text"]
    except Exception as exc:  # noqa: BLE001 - surface Bedrock errors to the client
        return _response(
            502,
            {
                "error": "Bedrock request failed.",
                "detail": str(exc),
                "hint": (
                    "Check that Nova model access is enabled in this region and "
                    "that the Lambda role can call bedrock:InvokeModel."
                ),
            },
        )

    # Parse the model's JSON, then normalize/sort defensively.
    try:
        plan = _extract_json(model_text)
    except (ValueError, json.JSONDecodeError):
        return _response(
            502,
            {"error": "Model did not return valid JSON.", "raw": model_text},
        )

    tasks = plan.get("tasks", [])
    for t in tasks:
        # Recompute the score so the UI is always consistent with urgency/impact.
        try:
            t["priority_score"] = int(t.get("urgency", 0)) * int(t.get("impact", 0))
        except (TypeError, ValueError):
            t["priority_score"] = 0
    tasks.sort(key=lambda t: t.get("priority_score", 0), reverse=True)
    plan["tasks"] = tasks

    # Keep "do_first" consistent with the actual top-ranked task after sorting.
    if tasks:
        plan["do_first"] = tasks[0].get("title", plan.get("do_first", ""))

    return _response(200, plan)
