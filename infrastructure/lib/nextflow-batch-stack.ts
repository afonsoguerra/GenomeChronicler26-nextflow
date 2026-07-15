import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as batch from 'aws-cdk-lib/aws-batch';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

/**
 * Minimal stack for running Nextflow pipelines on AWS Batch.
 *
 * Architecture:
 *   1. You submit a "head job" to AWS Batch (runs the nextflow/nextflow container)
 *   2. The head job (Nextflow orchestrator) submits child Batch jobs for each process/task
 *   3. Child jobs run in the same compute environment and queue
 *   4. S3 is used as the shared working directory
 *
 * Key permissions that Nextflow needs (and that many tutorials miss):
 *   - batch:RegisterJobDefinition  (Nextflow creates job defs for each process dynamically)
 *   - batch:DescribeJobDefinitions
 *   - batch:DescribeComputeEnvironments
 *   - batch:DescribeJobQueues
 *   - ecs:DescribeContainerInstances
 *   - ecs:DescribeTasks
 *   - ec2:DescribeInstances
 */
export class NextflowBatchStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ─── VPC ───────────────────────────────────────────────────────────────
    // Batch instances need outbound internet to pull Docker images.
    // NAT Gateway costs ~$1/day when idle, so destroy the stack when not in use.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        { name: 'Public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'Private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // ─── S3 Bucket (Nextflow work dir + output) ────────────────────────────
    const bucket = new s3.Bucket(this, 'WorkBucket', {
      bucketName: `nextflow-hello-${cdk.Aws.ACCOUNT_ID}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true, // Clean up on stack destroy for this test stack
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      lifecycleRules: [
        { id: 'ExpireWork', prefix: 'work/', expiration: cdk.Duration.days(3) },
      ],
    });

    // ─── CloudWatch Logs ───────────────────────────────────────────────────
    const logGroup = new logs.LogGroup(this, 'LogGroup', {
      logGroupName: '/nextflow-hello/batch',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── IAM: Head Job Role ────────────────────────────────────────────────
    // This role is assumed by the Nextflow head container (the orchestrator).
    // It needs broad Batch + S3 + Logs permissions because it manages everything.
    const headJobRole = new iam.Role(this, 'HeadJobRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
    });

    // S3: full access to our bucket (read input, write work dir + output)
    bucket.grantReadWrite(headJobRole);

    // CloudWatch Logs
    logGroup.grantWrite(headJobRole);

    // Batch: Nextflow needs to register job definitions, submit jobs, monitor them
    headJobRole.addToPolicy(new iam.PolicyStatement({
      sid: 'BatchFullAccess',
      actions: [
        'batch:SubmitJob',
        'batch:DescribeJobs',
        'batch:ListJobs',
        'batch:CancelJob',
        'batch:TerminateJob',
        'batch:RegisterJobDefinition',      // <-- Nextflow creates job defs dynamically!
        'batch:DeregisterJobDefinition',
        'batch:DescribeJobDefinitions',
        'batch:DescribeJobQueues',
        'batch:DescribeComputeEnvironments',
        'batch:TagResource',                 // <-- Nextflow 25.x tags job definitions it creates
      ],
      resources: ['*'],
    }));

    // ECS: Nextflow queries ECS to track task status
    headJobRole.addToPolicy(new iam.PolicyStatement({
      sid: 'EcsReadAccess',
      actions: [
        'ecs:DescribeTasks',
        'ecs:DescribeContainerInstances',
      ],
      resources: ['*'],
    }));

    // EC2: Nextflow checks instance IPs for log retrieval
    headJobRole.addToPolicy(new iam.PolicyStatement({
      sid: 'Ec2ReadAccess',
      actions: ['ec2:DescribeInstances'],
      resources: ['*'],
    }));

    // Logs: Nextflow reads task logs
    headJobRole.addToPolicy(new iam.PolicyStatement({
      sid: 'LogsReadAccess',
      actions: [
        'logs:GetLogEvents',
        'logs:CreateLogStream',
        'logs:PutLogEvents',
      ],
      resources: ['*'],
    }));

    // ─── IAM: Compute / Task Execution Role ────────────────────────────────
    // This role is used by the EC2 instances (ECS agent) AND by child task containers.
    const computeRole = new iam.Role(this, 'ComputeRole', {
      assumedBy: new iam.CompositePrincipal(
        new iam.ServicePrincipal('ec2.amazonaws.com'),
        new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      ),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonEC2ContainerServiceforEC2Role'),
      ],
    });

    // Child containers need S3 access (the actual pipeline tasks read/write data via S3)
    bucket.grantReadWrite(computeRole);

    // ECR public access for pulling images from public registries (ghcr.io, Docker Hub)
    computeRole.addToPolicy(new iam.PolicyStatement({
      sid: 'ECRPublicAccess',
      actions: [
        'ecr-public:GetAuthorizationToken',
        'ecr-public:BatchGetImage',
        'ecr-public:GetDownloadUrlForLayer',
        'sts:GetServiceBearerToken',
      ],
      resources: ['*'],
    }));

    // The head job needs PassRole so Nextflow can assign the compute role to child jobs
    headJobRole.addToPolicy(new iam.PolicyStatement({
      sid: 'PassComputeRole',
      actions: ['iam:PassRole'],
      resources: [computeRole.roleArn],
    }));

    // ─── Batch Compute Environment ─────────────────────────────────────────
    // Launch template: installs AWS CLI v2 to /usr/local/aws-cli on each instance,
    // then makes it available to all containers via a Docker volume.
    // This is the standard approach for Nextflow on AWS Batch — Nextflow uses
    // the AWS CLI inside task containers to stage files from S3.
    const launchTemplate = new ec2.LaunchTemplate(this, 'BatchLaunchTemplate', {
      userData: ec2.UserData.custom([
        'MIME-Version: 1.0',
        'Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="',
        '',
        '--==MYBOUNDARY==',
        'Content-Type: text/x-shellscript; charset="us-ascii"',
        '',
        '#!/bin/bash',
        'set -ex',
        '# Install AWS CLI v2 to the standard location',
        'yum install -y unzip',
        'curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"',
        'unzip -q /tmp/awscliv2.zip -d /tmp',
        '/tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin',
        'rm -rf /tmp/aws /tmp/awscliv2.zip',
        '',
        '--==MYBOUNDARY==--',
      ].join('\n')),
    });

    const computeEnv = new batch.ManagedEc2EcsComputeEnvironment(this, 'ComputeEnv', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      instanceRole: computeRole,
      instanceTypes: [
        ec2.InstanceType.of(ec2.InstanceClass.M5, ec2.InstanceSize.LARGE),
        ec2.InstanceType.of(ec2.InstanceClass.C5, ec2.InstanceSize.LARGE),
      ],
      maxvCpus: 8,
      minvCpus: 0,
      spot: true, // ~70% cheaper, fine for test workloads
      launchTemplate,
    });

    // ─── Batch Job Queue ───────────────────────────────────────────────────
    const jobQueue = new batch.JobQueue(this, 'JobQueue', {
      priority: 1,
      computeEnvironments: [{ computeEnvironment: computeEnv, order: 1 }],
    });

    // ─── Batch Job Definition (Nextflow head job) ──────────────────────────
    const jobDef = new batch.EcsJobDefinition(this, 'NextflowHeadJob', {
      container: new batch.EcsEc2ContainerDefinition(this, 'NextflowContainer', {
        image: ecs.ContainerImage.fromRegistry('nextflow/nextflow:25.04.3'),
        cpu: 2,
        memory: cdk.Size.mebibytes(4096),
        jobRole: headJobRole,
        environment: {
          // These are available for pipelines that read them, but we don't
          // force NXF_EXECUTOR here — let the command override decide.
          NXF_WORK: `s3://${bucket.bucketName}/work/`,
          BATCH_QUEUE: jobQueue.jobQueueName,
          AWS_REGION: cdk.Aws.REGION,
        },
        logging: ecs.LogDrivers.awsLogs({
          logGroup,
          streamPrefix: 'nextflow',
        }),
      }),
      timeout: cdk.Duration.hours(2),
      retryAttempts: 1,
    });

    // ─── Outputs ───────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'BucketName', { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'JobQueueArn', { value: jobQueue.jobQueueArn });
    new cdk.CfnOutput(this, 'JobQueueName', { value: jobQueue.jobQueueName });
    new cdk.CfnOutput(this, 'JobDefinitionArn', { value: jobDef.jobDefinitionArn });
    new cdk.CfnOutput(this, 'LogGroupName', { value: logGroup.logGroupName });
    new cdk.CfnOutput(this, 'VpcId', { value: vpc.vpcId });
  }
}
