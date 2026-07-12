# Brain Dump → Plan 🧠→✅

An AI-powered productivity tool for the **AWS Weekend Challenge**.

Empty your head into a text box — a jumbled stream of everything on your mind —
and get back a **clean, prioritized action plan**: tasks ranked by *urgency ×
impact*, grouped by category, with time estimates and a "do this first" pick.

It's the classic to-do prioritizer flipped on its head: instead of making *you*
do the work of writing a tidy list, you dump chaos and the AI does the
organizing. That's the twist.

## Architecture

Four AWS services, all comfortably in the **Free Tier**:

```
   Browser         API Gateway         AWS Lambda            Amazon Bedrock
  ┌──────────┐  POST   ┌──────────┐       ┌───────────────┐ Conv.   ┌──────────────┐
 │ index.html │ ────▶ │ HTTP API   │ ──▶ │ lambda_function │ ────▶ │  Nova Lite     │
 │ (Amplify)  │ ◀──── │ (public)   │ ◀── │  (Converse)     │ ◀──── │ (foundation    │
  └──────────┘  JSON   └──────────┘       └───────────────┘  plan  │   model)       │
                                                                    └──────────────┘
```

- **Amazon Bedrock (Nova Lite)** — the LLM that turns the dump into a plan.
- **AWS Lambda** — stateless backend that builds the prompt and calls Bedrock.
- **Amazon API Gateway (HTTP API)** — public front door for the Lambda.
- **AWS Amplify Hosting** — serves the single-page frontend.

No database, no auth, no servers to manage.

> **Why API Gateway instead of a Lambda Function URL?** A Function URL is
> simpler, but some AWS accounts reject anonymous (`AuthType NONE`) Function URL
> calls with `403 Forbidden`. An HTTP API with no authorizer is reliably public,
> lives on the standard `execute-api.amazonaws.com` domain (which corporate
> proxies allow), and is still Free Tier. `deploy.sh` sets this up for you.

```
.
├── lambda_function.py   # Lambda handler → Bedrock Converse API
├── index.html           # self-contained single-page UI  
├── deploy.sh            # creates role + Lambda + public HTTP API
├── trust-policy.json    # Lambda assume-role trust
├── bedrock-policy.json  # permission to invoke Nova
└── README.md
```

---

## Prerequisites

- An AWS account.
- **AWS CLI v2** installed (you already have it: `aws --version`).
- `zip` and `bash` (preinstalled on macOS/Linux).

---

## Step 1 — Configure AWS credentials

Create an access key in the AWS Console (**IAM → Users → your user → Security
credentials → Create access key → CLI**), then run:

```bash
aws configure
# AWS Access Key ID:     <paste>
# AWS Secret Access Key: <paste>
# Default region name:   us-east-1
# Default output format:  json
```

Verify:

```bash
aws sts get-caller-identity
```

> Use `us-east-1` (or `us-west-2`) — Nova models and their cross-region
> inference profiles are available there.

---

## Step 2 — Enable Amazon Bedrock Nova access

Bedrock requires you to request access to a model once, per region:

1. Open the **Amazon Bedrock** console in **us-east-1**.
2. Left nav → **Model access** → **Modify model access**.
3. Enable **Amazon → Nova Lite** (and Nova Micro/Pro if you want to experiment).
4. Submit. Amazon models are granted instantly.

Confirm from the CLI:

```bash
aws bedrock list-foundation-models --region us-east-1 \
  --query "modelSummaries[?contains(modelId,'nova-lite')].modelId"
```

---

## Step 3 — Deploy the backend

```bash
./deploy.sh
```

This creates the IAM role, deploys the Lambda, stands up a public HTTP API, and
prints your **API endpoint**. Re-running the script just updates the code and
config — it's safe to run repeatedly.

Test it directly (endpoint is printed at the end of the deploy):

```bash
curl -s -X POST '<YOUR_API_ENDPOINT>' \
  -H 'Content-Type: application/json' \
  -d '{"brain_dump":"call dentist, finish the deck for thursday, buy milk, mom birthday next week"}' | python3 -m json.tool
```

You should get back JSON with `summary`, `do_first`, and a sorted `tasks` array.

---

## Step 4 — Wire up the frontend

Open `index.html` and set the constant near the bottom:

```js
const API_URL = "https://<your-api-id>.execute-api.us-east-1.amazonaws.com/";
```

to the API endpoint printed in Step 3.

Test locally before hosting:

```bash
python3 -m http.server 8000
# open http://localhost:8000
```

---

## Step 5 — Host the frontend on AWS Amplify

**Easiest (drag-and-drop):**

1. Open the **AWS Amplify** console → **Create new app** → **Deploy without Git**.
2. Zip the frontend and upload it:
   ```bash
   zip -r ../site.zip index.html && cd ..
   ```
   Drag `site.zip` into the Amplify uploader.
3. Amplify gives you a public URL like `https://main.xxxx.amplifyapp.com`. Done.

**Or connect a Git repo** (Amplify auto-deploys on push) — point it at this repo
with the frontend directory as the app root; no build command is needed for a
static HTML file.

---

## Free Tier notes

- **Lambda** — 1M free requests + 400,000 GB-seconds/month, always free.
- **Bedrock Nova Lite** — pay-per-token and extremely cheap (fractions of a cent
  per plan); typical demo usage is well under $1. Bedrock is *not* free-tier-free,
  but Nova Lite is the cheapest Nova model — use `us.amazon.nova-micro-v1:0` to
  cut cost further.
- **Amplify Hosting** — free tier covers build minutes + hosting/storage for a
  small static site.

### Change the model

Set `MODEL_ID` before deploying to pick a different Nova model:

```bash
MODEL_ID="us.amazon.nova-micro-v1:0" ./deploy.sh   # cheapest/fastest
MODEL_ID="us.amazon.nova-pro-v1:0"   ./deploy.sh   # highest quality
```

---

## Cleanup (avoid any charges)

```bash
REGION=us-east-1

# Delete the HTTP API (look up its id by name first)
API_ID=$(aws apigatewayv2 get-apis --region $REGION \
  --query "Items[?Name=='brain-dump-api'].ApiId | [0]" --output text)
aws apigatewayv2 delete-api --api-id "$API_ID" --region $REGION

# Delete the Lambda (and its Function URL, if one was ever created)
aws lambda delete-function-url-config --function-name brain-dump-planner --region $REGION 2>/dev/null || true
aws lambda delete-function            --function-name brain-dump-planner --region $REGION

# Delete the IAM role + policies
aws iam delete-role-policy  --role-name brain-dump-planner-role --policy-name invoke-nova
aws iam detach-role-policy  --role-name brain-dump-planner-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role         --role-name brain-dump-planner-role
```

Then delete the Amplify app from the Amplify console.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `AccessDeniedException` / `...is not authorized to perform: bedrock:InvokeModel` | Enable Nova model access (Step 2) and confirm the region matches. |
| `ValidationException: ...on-demand throughput isn't supported` | Use the inference-profile id (`us.amazon.nova-lite-v1:0`), which is the default. |
| API returns `{"message":"Internal Server Error"}` | API Gateway couldn't invoke Lambda — check the integration URI is the full `arn:aws:lambda:...:function:...` ARN and that the `apigw-invoke` permission exists. `deploy.sh` handles both. |
| `403 Forbidden` on a Lambda **Function URL** | Some accounts block anonymous Function URLs — this project uses an API Gateway HTTP API instead (see the note under Architecture). |
| Frontend shows a CORS error | The Lambda returns CORS headers itself; make sure `API_URL` has no trailing space and matches the deployed endpoint. |
| `Set API_URL...` message in the UI | You haven't set `API_URL` in `index.html` yet (Step 4). |
