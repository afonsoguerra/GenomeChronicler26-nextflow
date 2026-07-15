# AWS Batch Deployment Post-Mortem

This document describes the issues encountered when deploying the GenomeChronicler Nextflow pipeline to AWS Batch via the CDK infrastructure stack, and the fixes applied.

**Branch:** `feat/aws-cdk-deployment`  
**Date:** 2026-07-14 / 2026-07-15  
**Nextflow version:** 26.04.6  
**Plugin:** nf-amazon 3.9.2 (auto-detected)

---

## Issue 1: `Cannot invoke "java.util.Map.get(Object)" because "opts" / "config" is null`

**Error:**
```
ERROR ~ Cannot invoke "java.util.Map.get(Object)" because "config" is null
```

Stack trace pointed to `AwsConfig.<init>(AwsConfig.groovy:53)`, triggered when Nextflow's `AwsBatchExecutor.createAwsClient()` attempted to initialise the AWS configuration.

**Root cause:**  
The nf-amazon plugin's `AwsConfig` constructor requires an explicit `aws {}` block in `nextflow.config`. Without it, the config map passed to the constructor is `null`. The CDK stack set `NXF_EXECUTOR=awsbatch` as an environment variable, which correctly told Nextflow to use the AWS Batch executor, but `NXF_EXECUTOR` does not initialise the `aws {}` config scope — that must be declared in the config file.

Additionally, `NXF_QUEUE` is **not** a recognised Nextflow environment variable. The CDK stack was setting it, but Nextflow never read it, so `process.queue` was never set.

**Fix (commit `fedc277`):**  
Added an `aws {}` block and `process.queue` assignment to `nextflow.config`, initially inside a conditional:

```groovy
if (System.getenv('NXF_EXECUTOR') == 'awsbatch') {
    process.executor = 'awsbatch'
    process.queue = System.getenv('NXF_QUEUE')
    aws {
        region = System.getenv('AWS_DEFAULT_REGION') ?: 'eu-west-2'
        batch {
            volumes = '/tmp'
        }
    }
}
```

**Verification:**  
Confirmed this was a pre-existing issue by checking out `main` and reproducing the same error — the `aws {}` block had never been present.

---

## Issue 2: Nextflow 26.x rejects `if` statements mixed with config DSL

**Error:**
```
Error nextflow.config:54:1: If statements cannot be mixed with config statements
```

**Root cause:**  
Nextflow 26.04.6 introduced stricter config parsing that forbids mixing imperative `if` statements with declarative config blocks in the same file. The conditional `if (System.getenv('NXF_EXECUTOR') == 'awsbatch')` block from Issue 1's fix was rejected.

**Fix (commit `a53a7be`):**  
Moved the AWS Batch configuration into a separate file `conf/awsbatch.config` which is unconditionally included via `includeConfig`. The `aws {}` block and `process.queue` are always loaded — they have no effect when the executor is not `awsbatch`. The executor itself is set via `NXF_EXECUTOR`, which Nextflow reads natively.

```groovy
// conf/awsbatch.config
process {
    queue = System.getenv('NXF_QUEUE') ?: null
}

aws {
    region = System.getenv('AWS_DEFAULT_REGION') ?: 'eu-west-2'
    batch {
        volumes = '/tmp'
    }
}
```

```groovy
// nextflow.config
includeConfig 'conf/awsbatch.config'
```

---

## Issue 3: `arity: '0..1'` not supported in Nextflow 26.04.6

**Error:**
```
Path arity 0..1 is not allowed
```

**Root cause:**  
An initial attempt to fix optional process inputs (BAM, VCF, VEP) used the `arity: '0..1'` qualifier on `path()` inputs to allow zero or one files. This syntax is not supported in Nextflow 26.04.6, and the parse failure cascaded into a misleading secondary error about `Missing plugin 'nf-amazon'` — the config never fully loaded, so the plugin was never initialised.

**Fix (commit `f751736`):**  
Reverted to the placeholder file approach. Empty sentinel files (`assets/NO_FILE`, `NO_FILE2`, `NO_FILE3`) are passed when an optional input is absent. The process script uses filename-based guards to detect their presence:

```groovy
// workflows/genomechronicler.nf
def bam_file = has_bam ? file(row.bam, checkIfExists: true) : file("${projectDir}/assets/NO_FILE")
def vcf_file = has_vcf ? file(row.vcf, checkIfExists: true) : file("${projectDir}/assets/NO_FILE2")
def vep_file = has_vep ? file(row.vep, checkIfExists: true) : file("${projectDir}/assets/NO_FILE3")
```

```groovy
// modules/local/genomechronicler/main.nf
def has_bam = bam.name != 'NO_FILE'
def has_vcf = vcf.name != 'NO_FILE2'
def has_vep = vep.name != 'NO_FILE3'
```

---

## Issue 4: Explicit `plugins {}` block broke auto-detection

**Error:**
```
Missing plugin 'nf-amazon' required to read file: s3://...
```

**Root cause:**  
Adding an explicit `plugins { id 'nf-amazon' }` declaration to `nextflow.config` interfered with Nextflow's automatic plugin detection. Nextflow auto-detects the need for nf-amazon when S3 paths are used, but the explicit declaration caused a loading conflict.

**Fix:**  
Removed the `plugins {}` block entirely. Nextflow auto-detects and downloads nf-amazon when it encounters S3 paths.

---

## Issue 5: Missing IAM permissions for HeadJobRole

**Error:**
```
User: arn:aws:sts::201263439413:assumed-role/GenomeChroniclerTestStack-HeadJobRoleE0DF92FC-.../...
is not authorized to perform: batch:DescribeJobDefinitions on resource: *
because no identity-based policy allows the batch:DescribeJobDefinitions action
```

**Root cause:**  
The CDK stack's `HeadJobRole` IAM policy (`BatchJobManagement`) only included `SubmitJob`, `DescribeJobs`, `ListJobs`, `CancelJob`, and `TerminateJob`. Nextflow's AWS Batch executor also needs to register and describe job definitions for worker tasks, query job queues, and describe compute environments.

**Fix (commit `f7eae2e`):**  
Added the missing permissions to the HeadJobRole in `infrastructure/lib/genome-chronicler-stack.ts`:

```typescript
actions: [
  'batch:SubmitJob',
  'batch:DescribeJobs',
  'batch:DescribeJobQueues',
  'batch:DescribeJobDefinitions',
  'batch:DescribeComputeEnvironments',
  'batch:RegisterJobDefinition',
  'batch:DeregisterJobDefinition',
  'batch:ListJobs',
  'batch:CancelJob',
  'batch:TerminateJob',
  'batch:TagResource',
]
```

Also expanded CloudWatch Logs permissions to include `logs:CreateLogGroup` and `logs:GetLogEvents`, and added the `:*` suffix to the log group ARN for log-stream-level operations.

---

## Issue 6: `task.ext.when` causes null config on AWS

**Error:**  
Same `"config" is null` error as Issue 1, but from a different code path — `ProcessDef.applyConfig`.

**Root cause:**  
The process definition originally included a `when: task.ext.when == null || task.ext.when` guard. On AWS Batch, `task.ext` was not initialised, causing a null reference when Nextflow tried to evaluate the `when` clause during config application.

**Fix (commit `849d153`):**  
Removed the `task.ext.when` block entirely — it was unnecessary since the workflow already validates inputs before invoking the process.

---

## Issue 7: Inactive job definition revision

**Error:**
```
JobDefinition ... is not in ACTIVE status
```

**Root cause:**  
After redeploying the CDK stack, a new job definition revision was created (e.g. `:4`), but the submit command was referencing the previous revision (e.g. `:3`). Old revisions are marked INACTIVE by AWS.

**Fix:**  
Updated the submit command to use the active revision ARN from `cdk deploy` outputs. The CDK stack's `SampleSubmitCommand` output always contains the correct revision.

---

## Issue 8: Spot instance interruptions

**Error:**
```
Host EC2 (instance i-...) terminated.
```

**Root cause:**  
The compute environment is configured with `spot: true`. Spot instances can be reclaimed by AWS at any time, killing the running container.

**Mitigation:**  
The job definition has `retryAttempts: 1`, and the pipeline can be resubmitted. For production use, consider:
- Setting `spot: false` for on-demand instances
- Adding more instance types to the compute environment for better spot availability
- Using Nextflow's `-resume` flag with the S3 work directory to resume from the last completed task

---

## Summary of commits

| Commit | Description |
|--------|-------------|
| `f751736` | Revert arity approach, use placeholder files with filename guards |
| `849d153` | Remove `task.ext.when` check that causes null config on AWS |
| `0f7a0c1` | Read AWS Batch queue from `NXF_QUEUE` env var |
| `6914936` | Set process executor and queue from env vars in config |
| `fedc277` | Add `aws {}` config block for AWS Batch executor |
| `f7eae2e` | Add missing IAM permissions for Nextflow head job on AWS Batch |
| `a53a7be` | Move AWS Batch config to separate file for NF 26.x compatibility |
