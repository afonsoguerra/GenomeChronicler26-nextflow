# Requirements Document

## Introduction

This document specifies the requirements for deploying the GenomeChronicler-nf Nextflow pipeline to AWS using AWS CDK (Cloud Development Kit). The deployment targets the **test configuration** (4 CPUs, 6 GB RAM, 2-hour max runtime) and provides all necessary infrastructure: networking, compute (AWS Batch), storage (S3), container image access, IAM roles, and a pipeline execution mechanism. An educational deployment guide document is also produced alongside the CDK code.

## Glossary

- **CDK_Stack**: The AWS CDK infrastructure-as-code stack that provisions all AWS resources for the GenomeChronicler pipeline deployment
- **VPC**: The Virtual Private Cloud network environment containing all deployed AWS resources with public and private subnets
- **S3_Bucket**: The Amazon S3 bucket used for storing pipeline input data (samplesheets, BAM/gVCF files) and output results (PDF reports, ancestry plots, genotype tables)
- **Batch_Compute_Environment**: The AWS Batch managed compute environment configured with EC2 instances sized for the test profile workload
- **Batch_Job_Queue**: The AWS Batch job queue that connects submitted pipeline jobs to the Batch_Compute_Environment
- **Batch_Job_Definition**: The AWS Batch job definition specifying the Nextflow head job container configuration, resource limits, and environment variables
- **Head_Job_Role**: The IAM execution role assumed by the Nextflow head job to orchestrate pipeline tasks via AWS Batch
- **Compute_Role**: The IAM instance role assigned to Batch compute instances for pulling containers and accessing S3 data
- **Pipeline_Launcher**: The mechanism (AWS Step Functions state machine or direct Batch job submission) that triggers pipeline execution
- **Deployment_Guide**: The educational markdown document explaining the architecture, manual setup steps, and operational procedures

## Requirements

### Requirement 1: VPC Networking

**User Story:** As a bioinformatics engineer, I want a properly configured VPC with public and private subnets, so that the pipeline compute resources have secure network access and can pull container images from external registries.

#### Acceptance Criteria

1. THE CDK_Stack SHALL provision a VPC with exactly two availability zones and a CIDR block providing at least a /16 address range
2. THE CDK_Stack SHALL provision the VPC with one public subnet and one private subnet per availability zone, using a single NAT gateway shared across availability zones to minimize cost
3. WHEN the CDK_Stack is deployed, THE VPC SHALL enable compute instances in private subnets to make outbound HTTPS (port 443) connections to external container registries (ghcr.io) via the NAT gateway
4. THE CDK_Stack SHALL tag all VPC resources (VPC, subnets, NAT gateway, internet gateway, route tables) with a "Project" tag set to "genomechronicler-test"
5. THE CDK_Stack SHALL configure the default security group for private subnets to allow all outbound traffic and deny all inbound traffic from outside the VPC

### Requirement 2: S3 Storage

**User Story:** As a bioinformatics engineer, I want an S3 bucket for pipeline data, so that input files (samplesheets, BAM/gVCF) and output results (PDF reports, ancestry plots) are stored durably and accessibly.

#### Acceptance Criteria

1. THE CDK_Stack SHALL create an S3_Bucket with a bucket name derived from a configurable prefix (provided as a CDK context parameter or construct prop, maximum 37 characters) appended with the AWS account ID or a unique suffix to ensure global uniqueness
2. THE CDK_Stack SHALL configure the S3_Bucket with versioning enabled
3. THE CDK_Stack SHALL configure the S3_Bucket with server-side encryption using SSE-S3
4. THE CDK_Stack SHALL block all public access to the S3_Bucket by enabling all four S3 Block Public Access settings
5. THE CDK_Stack SHALL configure the S3_Bucket with a lifecycle rule that transitions objects under the "input/" and "output/" prefixes to Infrequent Access storage after 30 days
6. THE CDK_Stack SHALL output the expected S3 prefix structure in the Deployment_Guide and as CloudFormation stack outputs: "input/" for samplesheets and source files, "output/" for pipeline results, and "work/" for Nextflow intermediate working files
7. THE CDK_Stack SHALL configure the S3_Bucket with a removal policy of RETAIN so that pipeline data is preserved if the stack is deleted

### Requirement 3: AWS Batch Compute Environment

**User Story:** As a bioinformatics engineer, I want an AWS Batch compute environment sized for the test profile, so that the pipeline has appropriate compute resources (4 vCPUs, 6 GB RAM) without over-provisioning.

#### Acceptance Criteria

1. THE CDK_Stack SHALL create a managed Batch_Compute_Environment of type EC2
2. THE CDK_Stack SHALL configure the Batch_Compute_Environment with a maximum of 4 vCPUs
3. THE CDK_Stack SHALL configure the Batch_Compute_Environment with instance types from the m5 family (m5.large) that provide at least 6 GB of memory per instance
4. THE CDK_Stack SHALL place the Batch_Compute_Environment instances in private subnets of the VPC
5. THE CDK_Stack SHALL configure the Batch_Compute_Environment with a minimum of 0 vCPUs so that instances are terminated when no jobs are queued
6. THE CDK_Stack SHALL assign the Compute_Role to instances in the Batch_Compute_Environment
7. THE CDK_Stack SHALL configure the Batch_Compute_Environment to use SPOT instances as the allocation strategy to minimize cost for the test workload

### Requirement 4: AWS Batch Job Queue and Job Definition

**User Story:** As a bioinformatics engineer, I want a Batch job queue and job definition for the Nextflow head job, so that I can submit pipeline runs and the head job has the correct resource allocation and container configuration.

#### Acceptance Criteria

1. THE CDK_Stack SHALL create a Batch_Job_Queue connected to the Batch_Compute_Environment with a priority of 1
2. THE CDK_Stack SHALL create a Batch_Job_Definition for the Nextflow head job container with the Head_Job_Role assigned as the job role
3. THE Batch_Job_Definition SHALL specify the container image as "nextflow/nextflow:latest" for the head job
4. THE Batch_Job_Definition SHALL allocate 2 vCPUs and 4096 MB memory to the head job container
5. THE Batch_Job_Definition SHALL set a job timeout of 7200 seconds (2 hours) matching the test profile max_time
6. THE Batch_Job_Definition SHALL configure environment variables NXF_WORK set to the S3_Bucket "work/" prefix path and NXF_OUTPUT set to the S3_Bucket "output/" prefix path for Nextflow to use as the work directory and output directory
7. IF the Nextflow head job fails with a non-zero exit code, THEN THE Batch_Job_Definition SHALL not retry the job (retry attempts set to 1)

### Requirement 5: IAM Roles and Permissions

**User Story:** As a bioinformatics engineer, I want properly scoped IAM roles for the Nextflow head job and the Batch compute instances, so that pipeline execution has the minimum permissions required to access S3 data and submit Batch jobs.

#### Acceptance Criteria

1. THE CDK_Stack SHALL create a Head_Job_Role with permissions to submit, describe, list, cancel, and terminate AWS Batch jobs scoped to the Batch_Job_Queue resource
2. THE Head_Job_Role SHALL have s3:GetObject, s3:PutObject, s3:DeleteObject, and s3:ListBucket permissions scoped to the S3_Bucket resource ARN and its objects
3. THE Head_Job_Role SHALL have iam:PassRole permission scoped to the Compute_Role ARN so that Nextflow can assign roles to spawned task containers
4. THE CDK_Stack SHALL create a Compute_Role (ECS instance role) with permissions to pull container images from public container registries via ecr-public:GetAuthorizationToken and ecr-public:BatchGetImage
5. THE Compute_Role SHALL have s3:GetObject, s3:PutObject, s3:DeleteObject, and s3:ListBucket permissions scoped to the S3_Bucket resource ARN for pipeline data staging
6. THE CDK_Stack SHALL create all IAM roles following the principle of least privilege with resource-scoped policies (no wildcard resource ARNs except where required by AWS service APIs)
7. THE Head_Job_Role SHALL have logs:CreateLogStream and logs:PutLogEvents permissions scoped to the CloudWatch Log Group ARN for pipeline monitoring

### Requirement 6: Container Image Access

**User Story:** As a bioinformatics engineer, I want the compute environment to pull the GenomeChronicler container image from GHCR, so that the pipeline process can execute without requiring a separate ECR repository.

#### Acceptance Criteria

1. THE Batch_Compute_Environment SHALL have network access to pull container images from ghcr.io and docker.io (Docker Hub) via the VPC NAT gateway
2. THE CDK_Stack SHALL configure the Nextflow head job environment to pass the container image reference "ghcr.io/pgp-uk/genomechronicler:latest" as a pipeline parameter so that Nextflow-spawned task containers use the correct image
3. THE Deployment_Guide SHALL document an alternative ECR mirror approach for cases where GHCR or Docker Hub anonymous pull rate limits are exceeded
4. THE Batch_Compute_Environment SHALL be configured to allow the ECS agent to pull container images from public registries (ghcr.io, docker.io) without requiring registry authentication

### Requirement 7: Pipeline Execution Trigger

**User Story:** As a bioinformatics engineer, I want a mechanism to trigger pipeline runs by specifying an input samplesheet path on S3, so that I can launch the GenomeChronicler pipeline without manual SSH access to instances.

#### Acceptance Criteria

1. THE CDK_Stack SHALL provide a Pipeline_Launcher that accepts an S3 path (in "s3://bucket/key" format) to a samplesheet CSV as required input, and optionally accepts an output S3 prefix and a Nextflow work directory S3 prefix
2. WHEN the Pipeline_Launcher is invoked, THE Pipeline_Launcher SHALL submit an AWS Batch job using the Batch_Job_Definition and return the Batch job ID to the caller
3. THE Pipeline_Launcher SHALL pass the samplesheet S3 path, output S3 prefix (defaulting to "s3://<S3_Bucket>/output/<job-id>/"), and Nextflow work directory (defaulting to "s3://<S3_Bucket>/work/<job-id>/") as parameters to the head job
4. THE Pipeline_Launcher SHALL configure the Nextflow head job to run with the "-profile docker,test" profiles
5. THE Pipeline_Launcher SHALL configure the Nextflow head job to use the "awsbatch" executor for task distribution to AWS Batch, passing the Batch_Job_Queue name and Compute_Role ARN as executor configuration
6. IF the Pipeline_Launcher is invoked with an S3 path that does not match the "s3://bucket/key" format, THEN THE Pipeline_Launcher SHALL reject the submission and return an error message indicating the path format is invalid

### Requirement 8: Monitoring and Logging

**User Story:** As a bioinformatics engineer, I want CloudWatch logging and basic monitoring for pipeline runs, so that I can track execution progress and diagnose failures.

#### Acceptance Criteria

1. THE CDK_Stack SHALL configure both the Nextflow head job and Nextflow-spawned child task jobs to route stdout and stderr to a dedicated CloudWatch Log Group
2. THE CDK_Stack SHALL create a CloudWatch Log Group named "/genomechronicler-test/batch" with a 14-day retention period for pipeline logs
3. THE CDK_Stack SHALL output the Log Group name as a CloudFormation stack output with the output key "LogGroupName" for easy access
4. THE CDK_Stack SHALL configure a log stream prefix structure of "nextflow/" for head job logs and "tasks/" for child task logs so engineers can locate logs for specific jobs

### Requirement 9: Educational Deployment Guide

**User Story:** As a bioinformatics engineer new to AWS, I want a comprehensive markdown guide explaining the architecture and manual setup steps, so that I can understand what the CDK stack provisions and troubleshoot issues.

#### Acceptance Criteria

1. THE Deployment_Guide SHALL explain the overall architecture with a component diagram in Mermaid format showing all AWS services (VPC, S3, Batch, IAM, CloudWatch) and the data flow between them (input upload → Batch execution → output retrieval)
2. THE Deployment_Guide SHALL document each AWS service provisioned by the CDK_Stack, including its role in the pipeline execution and its relationship to other services
3. THE Deployment_Guide SHALL provide step-by-step manual setup instructions covering each resource provisioned by the CDK_Stack (VPC, S3_Bucket, Batch_Compute_Environment, Batch_Job_Queue, Batch_Job_Definition, IAM roles, CloudWatch Log Group), ordered by dependency so that each step can be completed before the next
4. THE Deployment_Guide SHALL include a cost estimation section that itemizes per-service costs (EC2 compute, NAT gateway, S3 storage, data transfer) based on the test profile runtime of a single pipeline execution
5. THE Deployment_Guide SHALL document how to upload input data to S3 and trigger a pipeline run, including example AWS CLI commands for copying the samplesheet and source files to the S3 "input/" prefix and invoking the Pipeline_Launcher
6. THE Deployment_Guide SHALL document how to retrieve output results from S3 after pipeline completion, including example AWS CLI commands for listing and downloading files from the S3 "output/" prefix
7. THE Deployment_Guide SHALL include a troubleshooting section covering at minimum: container pull failures, insufficient resources, and IAM permission errors, where each entry documents the symptom (observable error), likely cause, and resolution steps
8. THE Deployment_Guide SHALL include a prerequisites section listing required tools (AWS CLI, AWS CDK, Docker), required AWS account configurations (permissions to create IAM roles, VPCs, and Batch resources), and assumed knowledge level

### Requirement 10: Work Directory Cleanup

**User Story:** As a bioinformatics engineer, I want the Nextflow work directory on S3 to be automatically cleaned up after a successful pipeline run, so that intermediate files do not accumulate and incur unnecessary storage costs.

#### Acceptance Criteria

1. THE CDK_Stack SHALL configure an S3 lifecycle rule on the "work/" prefix that expires objects after 7 days as a safety net for all pipeline runs
2. THE Deployment_Guide SHALL document the S3 lifecycle cleanup behavior and provide AWS CLI commands for manually inspecting or retaining specific work directory contents before expiration
3. THE Deployment_Guide SHALL document how to run `nextflow clean` pointing at the S3 work directory to immediately remove intermediate files after a successful run

### Requirement 11: Stack Outputs and Configuration

**User Story:** As a bioinformatics engineer, I want the CDK stack to export key resource identifiers as CloudFormation outputs, so that I can reference them in scripts and documentation.

#### Acceptance Criteria

1. THE CDK_Stack SHALL output the S3_Bucket name as a CloudFormation stack output with the output key "S3BucketName"
2. THE CDK_Stack SHALL output the Batch_Job_Queue ARN as a CloudFormation stack output with the output key "BatchJobQueueArn"
3. THE CDK_Stack SHALL output the Batch_Job_Definition ARN as a CloudFormation stack output with the output key "BatchJobDefinitionArn"
4. THE CDK_Stack SHALL output the VPC ID as a CloudFormation stack output with the output key "VpcId"
5. THE CDK_Stack SHALL output a sample AWS CLI `aws batch submit-job` command as a CloudFormation stack output with the output key "SampleSubmitCommand", where the command references the Batch_Job_Queue ARN and Batch_Job_Definition ARN from the stack and includes a placeholder for the samplesheet S3 path
6. THE CDK_Stack SHALL include a human-readable description on each CloudFormation stack output indicating the resource type and its purpose in the pipeline
