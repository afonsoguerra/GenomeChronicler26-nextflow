# Nextflow on AWS Batch — Runbook

---

## Part 1: Deploy the CDK Infrastructure

Run these steps once to create the AWS resources.

### Step 1: Log in to AWS

```bash
aws sso login
aws sts get-caller-identity
```

### Step 2: Export credentials for CDK

```bash
eval "$(aws configure export-credentials --profile default --format env)"
```

### Step 3: Install dependencies and deploy

```bash
cd ~/Desktop/AWS/AWS_hackathon2026/hello-world-batch/infrastructure
npm install

# First time only:
npx cdk bootstrap aws://201263439413/eu-west-2

# Deploy:
npx cdk deploy
```

Type `y` when prompted. Save the outputs (bucket name, job queue ARN, job definition ARN).

### Step 4: Tear down (when done, to stop costs)

```bash
cd ~/Desktop/AWS/AWS_hackathon2026/hello-world-batch/infrastructure
eval "$(aws configure export-credentials --profile default --format env)"
npx cdk destroy
```

NAT Gateway costs ~$1/day when idle, so destroy when not in use.

---

## Part 2: Submit a Pipeline

Three scripts are provided. All auto-detect ARNs from CloudFormation outputs.

### Option A: Hello World (basic test)

The simplest test — no input data, no file output. Proves the Batch infrastructure works.

```bash
./submit-hello.sh
```

### Option B: Hello 2 (writes output to S3)

Like hello-world but writes `hello.txt` to the S3 output directory.

```bash
./submit-hello2.sh
```

Download results:
```bash
aws s3 ls s3://nextflow-hello-201263439413/output/
aws s3 cp s3://nextflow-hello-201263439413/output/hello.txt .
```

### Option C: GenomeChronicler (real pipeline)

Runs the full GenomeChronicler pipeline on a gVCF/BAM sample.

**Before running:** upload input data to S3:

```bash
BUCKET_NAME="nextflow-hello-201263439413"

# Upload VCF file
aws s3 cp ~/Desktop/AWS/AWS_hackathon2026/data/uk33D02F_0.genotypingVCF.vcf.gz \
  s3://${BUCKET_NAME}/input/

# Create samplesheet with S3 paths and upload it
echo "sample,bam,vcf,vep" > /tmp/samplesheet.csv
echo "uk33D02F_0,,s3://${BUCKET_NAME}/input/uk33D02F_0.genotypingVCF.vcf.gz," >> /tmp/samplesheet.csv
aws s3 cp /tmp/samplesheet.csv s3://${BUCKET_NAME}/input/samplesheet.csv
```

**Submit:**

```bash
./submit-genomechronicler.sh
```

**Download results:**

```bash
aws s3 sync s3://nextflow-hello-201263439413/output/ ./gc_results/
```

---

## Monitoring Jobs

All three scripts print the job ID and monitoring commands. Quick reference:

```bash
# Check status
aws batch describe-jobs --jobs <JOB_ID> --query 'jobs[0].status' --output text

# Poll until done
while true; do
  STATUS=$(aws batch describe-jobs --jobs <JOB_ID> --query 'jobs[0].status' --output text)
  echo "$(date +%H:%M:%S): $STATUS"
  [[ "$STATUS" == "SUCCEEDED" || "$STATUS" == "FAILED" ]] && break
  sleep 30
done

# View logs
aws logs tail /nextflow-hello/batch --follow
```

---

## How the Submit Commands Work

Each script writes a Nextflow config file inside the head job container before running the pipeline:

```groovy
process.executor = "awsbatch"
process.queue = "JobQueueEE3AD499-..."
process.container = "public.ecr.aws/amazonlinux/amazonlinux:2023"  // hello pipelines only
aws.batch.cliPath = "/usr/local/aws-cli/v2/current/bin/aws"
aws.region = "eu-west-2"
```

**How the AWS CLI gets into child containers:**

Nextflow on AWS Batch needs the AWS CLI inside every task container to stage files from S3.
The CDK stack includes a **launch template** that installs AWS CLI v2 to `/usr/local/aws-cli/`
on each EC2 instance at boot. When Nextflow sees `aws.batch.cliPath`, it automatically mounts
the parent directory (`/usr/local/aws-cli`) from the host into each child container. This means
any container (GenomeChronicler, amazonlinux, etc.) gets the AWS CLI without needing it baked
into its Docker image.

**Why the config file is needed:**
1. The nf-amazon plugin crashes with "config is null" if no AWS Batch config exists in any config file
2. Command-line `-process.executor awsbatch` alone doesn't work (plugin loads before flags are parsed)

**Hello pipelines** additionally set `process.container = "amazonlinux:2023"` because the default
`quay.io/nextflow/bash` container is too minimal. GenomeChronicler doesn't need this because it
defines its own container (`ghcr.io/pgp-uk/genomechronicler:latest`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `"config" is null` | nf-amazon plugin can't find AWS Batch config | Use the `bash -c` + config file approach (scripts do this) |
| `SSL validation failed` / `aws: command not found` | Child container lacks AWS CLI | Fixed by launch template + volume mount |
| `batch:TagResource` denied | Missing IAM permission | Already fixed in this stack |
| `Local executor requires POSIX` | Work dir is S3 but executor is local | Must use `awsbatch` executor with S3 work dir |
| Stuck in RUNNABLE | Waiting for EC2 spot capacity | Wait a few minutes, or check vCPU limits |
| `:N not found` | Job definition revision doesn't exist | Check latest revision from `cdk deploy` outputs |
| `CannotPullContainerError` | Network issue pulling Docker image | Check NAT Gateway status |
