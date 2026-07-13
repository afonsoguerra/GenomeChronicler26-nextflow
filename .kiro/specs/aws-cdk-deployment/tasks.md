# Implementation Plan: AWS CDK Deployment for GenomeChronicler-nf

## Overview

This plan implements the AWS CDK infrastructure stack for deploying GenomeChronicler-nf to AWS Batch, along with an educational Deployment Guide. The CDK project is written in TypeScript and lives in the `infrastructure/` directory at the project root. Implementation proceeds from project scaffolding through individual resource constructs, IAM policies, CloudFormation outputs, testing, and finally the Deployment Guide.

## Tasks

- [ ] 1. Initialize CDK project structure and configuration
  - [ ] 1.1 Scaffold the CDK TypeScript project
    - Create `infrastructure/` directory with `bin/app.ts`, `lib/genome-chronicler-stack.ts`, `cdk.json`, `package.json`, `tsconfig.json`
    - Install dependencies: `aws-cdk-lib`, `constructs`, `@types/jest`, `jest`, `ts-jest`, `typescript`
    - Configure `cdk.json` with app entry point and context defaults (`bucketPrefix: "genomechronicler-test"`)
    - Define the `GenomeChroniclerStackProps` interface extending `cdk.StackProps` with optional `bucketPrefix` (max 37 chars)
    - Wire `bin/app.ts` to instantiate `GenomeChroniclerStack` reading context for `bucketPrefix`
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

- [ ] 2. Implement VPC networking
  - [ ] 2.1 Create the VPC construct with subnets and NAT gateway
    - Add VPC resource to `GenomeChroniclerStack` with 2 AZs, /16 CIDR, 1 NAT gateway
    - Configure public and private subnet configuration (PUBLIC + PRIVATE_WITH_EGRESS, /24 mask each)
    - Apply `Project: genomechronicler-test` tag to all VPC resources using `cdk.Tags.of(vpc).add()`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  - [ ]* 2.2 Write CDK assertion tests for VPC
    - Test VPC has exactly 2 AZs
    - Test exactly 1 NAT gateway is provisioned
    - Test private subnets exist with PRIVATE_WITH_EGRESS type
    - Test Project tag is applied
    - _Requirements: 1.1, 1.2, 1.4_

- [ ] 3. Implement S3 storage
  - [ ] 3.1 Create the S3 bucket with lifecycle rules
    - Add S3 Bucket construct with name `${bucketPrefix}-${Aws.ACCOUNT_ID}`
    - Enable versioning, SSE-S3 encryption, block all public access
    - Set removal policy to RETAIN
    - Add lifecycle rule: `input/` and `output/` transition to IA after 30 days
    - Add lifecycle rule: `work/` prefix expires after 7 days
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.7, 10.1_

  - [ ]* 3.2 Write CDK assertion tests for S3 bucket
    - Test bucket has versioning enabled
    - Test bucket has SSE-S3 encryption
    - Test block public access is enabled
    - Test lifecycle rules for input/, output/, and work/ prefixes
    - Test removal policy is RETAIN
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 2.7, 10.1_

- [ ] 4. Implement IAM roles and policies
  - [ ] 4.1 Create the Head Job Role with scoped permissions
    - Create IAM Role with `ecs-tasks.amazonaws.com` trust policy
    - Add inline policy: Batch actions (SubmitJob, DescribeJobs, ListJobs, CancelJob, TerminateJob) scoped to Job Queue ARN
    - Add inline policy: S3 actions (GetObject, PutObject, DeleteObject, ListBucket) scoped to bucket ARN
    - Add inline policy: `iam:PassRole` scoped to Compute Role ARN
    - Add inline policy: CloudWatch Logs (CreateLogStream, PutLogEvents) scoped to Log Group ARN
    - _Requirements: 5.1, 5.2, 5.3, 5.6, 5.7_

  - [ ] 4.2 Create the Compute Role with scoped permissions
    - Create IAM Role with `ec2.amazonaws.com` trust policy
    - Attach managed policy `AmazonECSTaskExecutionRolePolicy`
    - Add inline policy: ECR public actions (GetAuthorizationToken, BatchGetImage) with `*` resource (service requirement)
    - Add inline policy: `sts:GetServiceBearerToken` with `*` resource
    - Add inline policy: S3 actions (GetObject, PutObject, DeleteObject, ListBucket) scoped to bucket ARN
    - _Requirements: 5.4, 5.5, 5.6_

  - [ ]* 4.3 Write CDK assertion tests for IAM roles
    - Test Head Job Role has correct trust policy
    - Test Head Job Role policies are scoped to specific resource ARNs (no wildcard except where required)
    - Test Compute Role has ECS managed policy attached
    - Test Compute Role has S3 permissions scoped to bucket ARN
    - Test no wildcard resources except for ECR public and STS
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_

- [ ] 5. Implement Batch compute environment and job queue
  - [ ] 5.1 Create the Batch Compute Environment
    - Add `ManagedEc2EcsComputeEnvironment` construct in private subnets
    - Configure: m5.large instance type, SPOT allocation, maxvCpus=4, minvCpus=0
    - Assign the Compute Role as instance role
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 6.1, 6.4_

  - [ ] 5.2 Create the Batch Job Queue
    - Add `JobQueue` construct with priority 1
    - Connect to the Compute Environment with order 1
    - _Requirements: 4.1_

  - [ ]* 5.3 Write CDK assertion tests for Batch resources
    - Test Compute Environment uses SPOT allocation
    - Test Compute Environment max vCPUs is 4, min vCPUs is 0
    - Test Compute Environment is placed in private subnets
    - Test Job Queue priority is 1 and is connected to Compute Environment
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 4.1_

- [ ] 6. Implement Batch Job Definition and CloudWatch logging
  - [ ] 6.1 Create the CloudWatch Log Group
    - Add Log Group construct with name `/genomechronicler-test/batch`
    - Set retention to 14 days
    - Set removal policy to DESTROY
    - _Requirements: 8.1, 8.2, 8.4_

  - [ ] 6.2 Create the Batch Job Definition for the Nextflow head job
    - Add `EcsJobDefinition` with `EcsEc2ContainerDefinition`
    - Container image: `nextflow/nextflow:latest`
    - Resources: 2 vCPUs, 4096 MB memory
    - Assign Head Job Role as the job role
    - Set timeout to 7200 seconds, retryAttempts to 1
    - Configure environment variables: `NXF_WORK` and `NXF_OUTPUT` pointing to S3 bucket prefixes
    - Configure awsLogs log driver with the Log Group and `nextflow` stream prefix
    - _Requirements: 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 6.2, 8.1, 8.4_

  - [ ]* 6.3 Write CDK assertion tests for Job Definition and CloudWatch
    - Test Job Definition has correct container image
    - Test Job Definition allocates 2 vCPUs and 4096 MB
    - Test Job Definition timeout is 7200 seconds
    - Test Job Definition retry attempts is 1
    - Test environment variables NXF_WORK and NXF_OUTPUT are set
    - Test Log Group has 14-day retention and correct name
    - _Requirements: 4.3, 4.4, 4.5, 4.6, 4.7, 8.2_

- [ ] 7. Checkpoint - Verify core infrastructure
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 8. Implement CloudFormation outputs
  - [ ] 8.1 Add all CloudFormation stack outputs
    - Output `S3BucketName`: bucket name with description
    - Output `BatchJobQueueArn`: job queue ARN with description
    - Output `BatchJobDefinitionArn`: job definition ARN with description
    - Output `VpcId`: VPC ID with description
    - Output `LogGroupName`: log group name with description
    - Output `SampleSubmitCommand`: full `aws batch submit-job` CLI command with placeholders for samplesheet S3 path, referencing queue ARN and job definition ARN from the stack
    - Add human-readable descriptions to each output
    - _Requirements: 8.3, 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

  - [ ]* 8.2 Write CDK assertion tests for CloudFormation outputs
    - Test all 6 outputs are present in the synthesized template
    - Test each output has a description
    - Test SampleSubmitCommand references the correct resources
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

- [ ] 9. Write snapshot test
  - [ ] 9.1 Create a snapshot test for the full stack template
    - Add snapshot test in `infrastructure/test/genome-chronicler-stack.test.ts`
    - Synthesize the stack and compare against stored snapshot
    - This captures the complete CloudFormation template for regression detection
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

- [ ] 10. Checkpoint - Verify all CDK tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 11. Create the Deployment Guide
  - [ ] 11.1 Write the Deployment Guide markdown document
    - Create `infrastructure/docs/deployment-guide.md`
    - Include prerequisites section (AWS CLI, CDK, Docker, Node.js, AWS permissions)
    - Include architecture overview with Mermaid component diagram showing VPC, S3, Batch, IAM, CloudWatch, and data flow
    - Document each AWS service provisioned (VPC, S3, Batch CE, Job Queue, Job Definition, IAM roles, CloudWatch) with role and relationships
    - Provide step-by-step manual setup instructions ordered by dependency
    - Include CDK deployment commands (`cdk bootstrap`, `cdk deploy`)
    - _Requirements: 9.1, 9.2, 9.3, 9.8_

  - [ ] 11.2 Document pipeline execution and data management
    - Document how to upload input data to S3 with AWS CLI examples (copy samplesheet and source files to `input/` prefix)
    - Document how to trigger a pipeline run using the `SampleSubmitCommand` output (the Pipeline Launcher pattern)
    - Include input validation note (S3 path format `s3://bucket/key`)
    - Document how to retrieve output results from S3 with AWS CLI examples (list and download from `output/` prefix)
    - Document the S3 lifecycle cleanup behavior for the `work/` prefix (7-day expiration)
    - Document `nextflow clean` command for immediate work directory cleanup
    - Document how to inspect or retain specific work directory contents before expiration
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 9.5, 9.6, 10.2, 10.3_

  - [ ] 11.3 Document monitoring, troubleshooting, and cost estimation
    - Document CloudWatch log access and log stream prefix structure (`nextflow/` and `tasks/`)
    - Include troubleshooting section: container pull failures, insufficient resources, IAM permission errors, SPOT reclamation, pipeline timeout
    - Document Nextflow resume strategy for recovering from failures
    - Include cost estimation section itemizing: EC2 SPOT compute, NAT gateway hourly + data, S3 storage + requests, data transfer
    - Document the alternative ECR mirror approach for rate-limited environments
    - _Requirements: 6.3, 8.3, 8.4, 9.4, 9.7_

- [ ] 12. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- The design specifies CDK assertion tests (not property-based tests) since this is an IaC project
- Unit tests use Jest with `aws-cdk-lib/assertions` — no PBT framework needed
- The Pipeline Launcher is a documented CLI pattern in the Deployment Guide, not a separate AWS resource
- Container images are pulled directly from ghcr.io; ECR mirror is documented as an alternative

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["2.1", "3.1", "6.1"] },
    { "id": 2, "tasks": ["2.2", "3.2", "4.1", "4.2"] },
    { "id": 3, "tasks": ["4.3", "5.1"] },
    { "id": 4, "tasks": ["5.2", "5.3"] },
    { "id": 5, "tasks": ["6.2"] },
    { "id": 6, "tasks": ["6.3", "8.1"] },
    { "id": 7, "tasks": ["8.2", "9.1"] },
    { "id": 8, "tasks": ["11.1", "11.2", "11.3"] }
  ]
}
```
