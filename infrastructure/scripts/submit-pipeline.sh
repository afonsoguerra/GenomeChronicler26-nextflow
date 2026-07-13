#!/usr/bin/env bash
#
# submit-pipeline.sh — Launch a GenomeChronicler pipeline run on AWS Batch
#
# Usage:
#   ./submit-pipeline.sh s3://bucket/input/samplesheet.csv
#
# Environment variables (or pass as arguments):
#   BATCH_JOB_QUEUE_ARN     — ARN of the Batch job queue
#   BATCH_JOB_DEF_ARN       — ARN of the Batch job definition
#   BUCKET_NAME             — S3 bucket name for pipeline data
#
# The script validates the S3 path format before submitting.
#

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

SAMPLESHEET_S3_PATH="${1:-}"
JOB_QUEUE="${BATCH_JOB_QUEUE_ARN:-}"
JOB_DEF="${BATCH_JOB_DEF_ARN:-}"
BUCKET="${BUCKET_NAME:-}"

# ─── Validation ─────────────────────────────────────────────────────────────

if [[ -z "$SAMPLESHEET_S3_PATH" ]]; then
  echo "ERROR: Samplesheet S3 path is required."
  echo "Usage: $0 s3://bucket/path/to/samplesheet.csv"
  exit 1
fi

# Validate S3 path format
if [[ ! "$SAMPLESHEET_S3_PATH" =~ ^s3://[a-zA-Z0-9.-]+/.+ ]]; then
  echo "ERROR: Invalid S3 path format: '$SAMPLESHEET_S3_PATH'"
  echo "Expected format: s3://bucket-name/key/path.csv"
  exit 1
fi

if [[ -z "$JOB_QUEUE" ]]; then
  echo "ERROR: BATCH_JOB_QUEUE_ARN environment variable not set."
  echo "Set it from CDK outputs: export BATCH_JOB_QUEUE_ARN=arn:aws:batch:..."
  exit 1
fi

if [[ -z "$JOB_DEF" ]]; then
  echo "ERROR: BATCH_JOB_DEF_ARN environment variable not set."
  echo "Set it from CDK outputs: export BATCH_JOB_DEF_ARN=arn:aws:batch:..."
  exit 1
fi

if [[ -z "$BUCKET" ]]; then
  echo "ERROR: BUCKET_NAME environment variable not set."
  echo "Set it from CDK outputs: export BUCKET_NAME=genomechronicler-test-..."
  exit 1
fi

# ─── Submit Job ─────────────────────────────────────────────────────────────

JOB_NAME="genomechronicler-$(date +%Y%m%d-%H%M%S)"

echo "Submitting pipeline job..."
echo "  Job name:    $JOB_NAME"
echo "  Samplesheet: $SAMPLESHEET_S3_PATH"
echo "  Output:      s3://${BUCKET}/output/"
echo "  Work dir:    s3://${BUCKET}/work/"
echo ""

RESULT=$(aws batch submit-job \
  --job-name "$JOB_NAME" \
  --job-queue "$JOB_QUEUE" \
  --job-definition "$JOB_DEF" \
  --container-overrides '{
    "command": [
      "nextflow", "run",
      "https://github.com/PGP-UK/GenomeChronicler26-nextflow",
      "--input", "'"${SAMPLESHEET_S3_PATH}"'",
      "--outdir", "s3://'"${BUCKET}"'/output/",
      "--gc_container", "ghcr.io/pgp-uk/genomechronicler:latest",
      "-profile", "docker,test",
      "-work-dir", "s3://'"${BUCKET}"'/work/"
    ]
  }')

JOB_ID=$(echo "$RESULT" | grep -o '"jobId": "[^"]*"' | cut -d'"' -f4)

echo "Job submitted successfully!"
echo "  Job ID: $JOB_ID"
echo ""
echo "Monitor with:"
echo "  aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].status'"
echo ""
echo "View logs:"
echo "  aws logs tail /genomechronicler-test/batch --follow"
