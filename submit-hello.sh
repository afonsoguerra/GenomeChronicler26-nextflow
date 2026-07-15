#!/usr/bin/env bash
#
# submit-hello.sh — Submit the Nextflow hello-world pipeline to AWS Batch
#
# Usage:
#   ./submit-hello.sh
#
# Before running:
#   1. Deploy the CDK stack (see README_INFRASTRUCTURE.md)
#   2. Either let this script auto-detect outputs from CloudFormation,
#      or set these env vars manually:
#        export JOB_QUEUE_ARN=arn:aws:batch:...
#        export JOB_DEF_ARN=arn:aws:batch:...
#        export BUCKET_NAME=nextflow-hello-...
#

set -euo pipefail

STACK_NAME="NextflowBatchHelloStack"
REGION="eu-west-2"

# ─── Auto-detect from CloudFormation outputs if not set ─────────────────────

if [[ -z "${JOB_QUEUE_ARN:-}" || -z "${JOB_DEF_ARN:-}" || -z "${BUCKET_NAME:-}" ]]; then
  echo "Fetching stack outputs from CloudFormation..."
  OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs' \
    --output json 2>/dev/null) || {
    echo "ERROR: Stack '$STACK_NAME' not found. Deploy it first (see README_INFRASTRUCTURE.md)."
    exit 1
  }

  JOB_QUEUE_ARN=$(echo "$OUTPUTS" | python3 -c "
import sys, json
outputs = json.load(sys.stdin)
for o in outputs:
    if 'JobQueueArn' in o['OutputKey']: print(o['OutputValue'])
")
  JOB_DEF_ARN=$(echo "$OUTPUTS" | python3 -c "
import sys, json
outputs = json.load(sys.stdin)
for o in outputs:
    if 'JobDefinitionArn' in o['OutputKey']: print(o['OutputValue'])
")
  BUCKET_NAME=$(echo "$OUTPUTS" | python3 -c "
import sys, json
outputs = json.load(sys.stdin)
for o in outputs:
    if 'BucketName' in o['OutputKey']: print(o['OutputValue'])
")
fi

# ─── Validate ───────────────────────────────────────────────────────────────

if [[ -z "$JOB_QUEUE_ARN" || -z "$JOB_DEF_ARN" || -z "$BUCKET_NAME" ]]; then
  echo "ERROR: Could not determine stack outputs."
  echo "Set these manually:"
  echo "  export JOB_QUEUE_ARN=arn:aws:batch:..."
  echo "  export JOB_DEF_ARN=arn:aws:batch:..."
  echo "  export BUCKET_NAME=nextflow-hello-..."
  exit 1
fi

# Extract queue name from ARN (everything after last /)
QUEUE_NAME="${JOB_QUEUE_ARN##*/}"

# ─── Submit ─────────────────────────────────────────────────────────────────

JOB_NAME="hello-$(date +%Y%m%d-%H%M%S)"

echo ""
echo "Submitting Nextflow hello-world pipeline..."
echo "  Job name:   $JOB_NAME"
echo "  Queue:      $JOB_QUEUE_ARN"
echo "  Definition: $JOB_DEF_ARN"
echo "  Work dir:   s3://${BUCKET_NAME}/work/"
echo ""

# The command creates a Nextflow config file inside the container, then runs the pipeline.
# This is needed because:
#   1. The nf-amazon plugin crashes if no AWS Batch config exists in any config file
#   2. The default quay.io/nextflow/bash container lacks SSL certificates
#   3. Command-line -process.executor flag alone doesn't work (plugin loads before flags)

CONTAINER_OVERRIDES="{
    \"command\": [\"bash\", \"-c\", \"cat > /tmp/batch.config <<EOF\nprocess.executor = \\\"awsbatch\\\"\nprocess.queue = \\\"${QUEUE_NAME}\\\"\nprocess.container = \\\"public.ecr.aws/amazonlinux/amazonlinux:2023\\\"\naws.batch.cliPath = \\\"/usr/local/aws-cli/v2/current/bin/aws\\\"\naws.region = \\\"${REGION}\\\"\nEOF\nnextflow run hello -c /tmp/batch.config -work-dir s3://${BUCKET_NAME}/work/\"]
  }"

echo "Command:"
echo "────────"
echo "aws batch submit-job \\"
echo "  --job-name \"$JOB_NAME\" \\"
echo "  --job-queue \"$JOB_QUEUE_ARN\" \\"
echo "  --job-definition \"$JOB_DEF_ARN\" \\"
echo "  --container-overrides '${CONTAINER_OVERRIDES}'"
echo ""

RESULT=$(aws batch submit-job \
  --job-name "$JOB_NAME" \
  --job-queue "$JOB_QUEUE_ARN" \
  --job-definition "$JOB_DEF_ARN" \
  --container-overrides "$CONTAINER_OVERRIDES")

echo "$RESULT"
echo ""

# Extract job ID
JOB_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")

echo "──────────────────────────────────────────"
echo "  Job ID: $JOB_ID"
echo "──────────────────────────────────────────"
echo ""
echo "Monitor with:"
echo "  aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].status' --output text"
echo ""
echo "View logs:"
echo "  aws logs tail /nextflow-hello/batch --follow"
echo ""
echo "Poll until done:"
echo "  while true; do"
echo "    STATUS=\$(aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].status' --output text)"
echo "    echo \"\$(date +%H:%M:%S): \$STATUS\""
echo "    [[ \"\$STATUS\" == \"SUCCEEDED\" || \"\$STATUS\" == \"FAILED\" ]] && break"
echo "    sleep 30"
echo "  done"
echo ""
