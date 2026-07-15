#!/usr/bin/env bash
#
# submit-hello2.sh — Submit the hello_2 pipeline (writes output to S3) to AWS Batch
#
# Usage:
#   ./submit-hello2.sh
#
# Pipeline: https://github.com/lconde-ucl/hello_2
# Same as hello-world but has a helloTask process that writes hello.txt to --outdir
#

set -euo pipefail

STACK_NAME="NextflowBatchHelloStack"
REGION="eu-west-2"
PIPELINE_URL="https://github.com/lconde-ucl/hello_2"

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
OUTDIR="s3://${BUCKET_NAME}/output/"

# ─── Submit ─────────────────────────────────────────────────────────────────

JOB_NAME="hello2-$(date +%Y%m%d-%H%M%S)"

echo ""
echo "Submitting hello_2 pipeline..."
echo "  Job name:   $JOB_NAME"
echo "  Pipeline:   $PIPELINE_URL"
echo "  Queue:      $JOB_QUEUE_ARN"
echo "  Definition: $JOB_DEF_ARN"
echo "  Work dir:   s3://${BUCKET_NAME}/work/"
echo "  Output:     $OUTDIR"
echo ""

CONTAINER_OVERRIDES="{
    \"command\": [\"bash\", \"-c\", \"cat > /tmp/batch.config <<EOF\nprocess.executor = \\\"awsbatch\\\"\nprocess.queue = \\\"${QUEUE_NAME}\\\"\nprocess.container = \\\"public.ecr.aws/amazonlinux/amazonlinux:2023\\\"\naws.batch.cliPath = \\\"/usr/local/aws-cli/v2/current/bin/aws\\\"\naws.region = \\\"${REGION}\\\"\nEOF\nnextflow run ${PIPELINE_URL} --outdir ${OUTDIR} -c /tmp/batch.config -work-dir s3://${BUCKET_NAME}/work/\"]
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
echo "Download output when done:"
echo "  aws s3 ls ${OUTDIR}"
echo "  aws s3 cp ${OUTDIR}hello.txt ."
echo ""
