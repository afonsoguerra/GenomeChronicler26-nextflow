#!/usr/bin/env bash
#
# submit-genomechronicler.sh — Submit the GenomeChronicler pipeline to AWS Batch
#
# Usage:
#   ./submit-genomechronicler.sh
#
# Before running:
#   1. Deploy the CDK stack (see README_INFRASTRUCTURE.md)
#   2. Upload your input data to S3:
#        aws s3 cp your_file.vcf.gz s3://${BUCKET_NAME}/input/
#        aws s3 cp samplesheet.csv s3://${BUCKET_NAME}/input/samplesheet.csv
#      Make sure the samplesheet references S3 paths, e.g.:
#        sample,bam,vcf,vep
#        uk33D02F_0,,s3://nextflow-hello-201263439413/input/uk33D02F_0.genotypingVCF.vcf.gz,
#

set -euo pipefail

STACK_NAME="NextflowBatchHelloStack"
REGION="eu-west-2"
PIPELINE_URL="https://github.com/afonsoguerra/GenomeChronicler26-nextflow"
PIPELINE_BRANCH="feat/aws-cdk-deployment"
GC_CONTAINER="ghcr.io/pgp-uk/genomechronicler:latest"

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

# Check that input samplesheet exists in S3
SAMPLESHEET="s3://${BUCKET_NAME}/input/samplesheet.csv"
if ! aws s3 ls "$SAMPLESHEET" >/dev/null 2>&1; then
  echo "ERROR: Samplesheet not found at $SAMPLESHEET"
  echo ""
  echo "Upload your data first:"
  echo "  aws s3 cp your_file.vcf.gz s3://${BUCKET_NAME}/input/"
  echo "  aws s3 cp samplesheet.csv s3://${BUCKET_NAME}/input/samplesheet.csv"
  echo ""
  echo "Samplesheet format (VCF paths must be full S3 URIs):"
  echo "  sample,bam,vcf,vep"
  echo "  uk33D02F_0,,s3://${BUCKET_NAME}/input/uk33D02F_0.genotypingVCF.vcf.gz,"
  exit 1
fi

# Extract queue name from ARN (everything after last /)
QUEUE_NAME="${JOB_QUEUE_ARN##*/}"
OUTDIR="s3://${BUCKET_NAME}/output/"

# ─── Submit ─────────────────────────────────────────────────────────────────

JOB_NAME="gc-$(date +%Y%m%d-%H%M%S)"

echo ""
echo "Submitting GenomeChronicler pipeline..."
echo "  Job name:    $JOB_NAME"
echo "  Pipeline:    $PIPELINE_URL (-r $PIPELINE_BRANCH)"
echo "  Container:   $GC_CONTAINER"
echo "  Queue:       $JOB_QUEUE_ARN"
echo "  Definition:  $JOB_DEF_ARN"
echo "  Samplesheet: $SAMPLESHEET"
echo "  Work dir:    s3://${BUCKET_NAME}/work/"
echo "  Output:      $OUTDIR"
echo ""

CONTAINER_OVERRIDES="{
    \"command\": [\"bash\", \"-c\", \"cat > /tmp/batch.config <<EOF\nprocess.executor = \\\"awsbatch\\\"\nprocess.queue = \\\"${QUEUE_NAME}\\\"\naws.batch.cliPath = \\\"/usr/local/aws-cli/v2/current/bin/aws\\\"\naws.region = \\\"${REGION}\\\"\nEOF\nnextflow run ${PIPELINE_URL} -r ${PIPELINE_BRANCH} --input ${SAMPLESHEET} --outdir ${OUTDIR} --gc_container ${GC_CONTAINER} -profile docker,test -c /tmp/batch.config -work-dir s3://${BUCKET_NAME}/work/\"]
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
echo "Download results when done:"
echo "  aws s3 sync ${OUTDIR} ./gc_results/"
echo ""
echo "Poll until done:"
echo "  while true; do"
echo "    STATUS=\$(aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].status' --output text)"
echo "    echo \"\$(date +%H:%M:%S): \$STATUS\""
echo "    [[ \"\$STATUS\" == \"SUCCEEDED\" || \"\$STATUS\" == \"FAILED\" ]] && break"
echo "    sleep 30"
echo "  done"
echo ""
