import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as batch from 'aws-cdk-lib/aws-batch';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

export interface GenomeChroniclerStackProps extends cdk.StackProps {
  /**
   * Prefix for the S3 bucket name. Max 37 characters.
   * Account ID is appended for global uniqueness.
   * @default "genomechronicler-test"
   */
  bucketPrefix?: string;
}

export class GenomeChroniclerStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;
  public readonly bucket: s3.Bucket;
  public readonly headJobRole: iam.Role;
  public readonly computeRole: iam.Role;
  public readonly computeEnvironment: batch.ManagedEc2EcsComputeEnvironment;
  public readonly jobQueue: batch.JobQueue;
  public readonly jobDefinition: batch.EcsJobDefinition;
  public readonly logGroup: logs.LogGroup;

  constructor(scope: Construct, id: string, props: GenomeChroniclerStackProps = {}) {
    super(scope, id, props);

    const bucketPrefix = props.bucketPrefix ?? 'genomechronicler-test';

    // ─── VPC ───────────────────────────────────────────────────────────────────
    this.vpc = new ec2.Vpc(this, 'PipelineVpc', {
      maxAzs: 2,
      ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
      natGateways: 1,
      subnetConfiguration: [
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
        {
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24,
        },
      ],
    });

    cdk.Tags.of(this.vpc).add('Project', 'genomechronicler-test');

    // ─── S3 Bucket ─────────────────────────────────────────────────────────────
    this.bucket = new s3.Bucket(this, 'DataBucket', {
      bucketName: `${bucketPrefix}-${cdk.Aws.ACCOUNT_ID}`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          id: 'TransitionInputToIA',
          prefix: 'input/',
          transitions: [
            {
              storageClass: s3.StorageClass.INFREQUENT_ACCESS,
              transitionAfter: cdk.Duration.days(30),
            },
          ],
        },
        {
          id: 'TransitionOutputToIA',
          prefix: 'output/',
          transitions: [
            {
              storageClass: s3.StorageClass.INFREQUENT_ACCESS,
              transitionAfter: cdk.Duration.days(30),
            },
          ],
        },
        {
          id: 'ExpireWorkDir',
          prefix: 'work/',
          expiration: cdk.Duration.days(7),
        },
      ],
    });

    // ─── CloudWatch Log Group ──────────────────────────────────────────────────
    this.logGroup = new logs.LogGroup(this, 'PipelineLogGroup', {
      logGroupName: '/genomechronicler-test/batch',
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── IAM: Compute Role (ECS instance role) ─────────────────────────────────
    this.computeRole = new iam.Role(this, 'ComputeRole', {
      assumedBy: new iam.CompositePrincipal(
        new iam.ServicePrincipal('ec2.amazonaws.com'),
        new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      ),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          'service-role/AmazonEC2ContainerServiceforEC2Role',
        ),
      ],
    });

    // Compute Role: ECR Public access (requires * resource per AWS docs)
    this.computeRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ECRPublicAccess',
        actions: [
          'ecr-public:GetAuthorizationToken',
          'ecr-public:BatchGetImage',
          'ecr-public:GetDownloadUrlForLayer',
          'sts:GetServiceBearerToken',
        ],
        resources: ['*'],
      }),
    );

    // Compute Role: S3 access scoped to pipeline bucket
    this.computeRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'S3DataAccess',
        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
        resources: [this.bucket.arnForObjects('*')],
      }),
    );
    this.computeRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'S3ListBucket',
        actions: ['s3:ListBucket'],
        resources: [this.bucket.bucketArn],
      }),
    );

    // ─── IAM: Head Job Role ────────────────────────────────────────────────────
    this.headJobRole = new iam.Role(this, 'HeadJobRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
    });

    // Head Job Role: S3 access
    this.headJobRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'S3DataAccess',
        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
        resources: [this.bucket.arnForObjects('*')],
      }),
    );
    this.headJobRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'S3ListBucket',
        actions: ['s3:ListBucket'],
        resources: [this.bucket.bucketArn],
      }),
    );

    // Head Job Role: CloudWatch Logs
    this.headJobRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'CloudWatchLogs',
        actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
        resources: [this.logGroup.logGroupArn],
      }),
    );

    // Head Job Role: PassRole to Compute Role (Nextflow needs this to assign roles to task containers)
    this.headJobRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'PassComputeRole',
        actions: ['iam:PassRole'],
        resources: [this.computeRole.roleArn],
      }),
    );

    // ─── Batch Compute Environment ─────────────────────────────────────────────
    this.computeEnvironment = new batch.ManagedEc2EcsComputeEnvironment(
      this,
      'ComputeEnv',
      {
        vpc: this.vpc,
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
        instanceRole: this.computeRole,
        instanceTypes: [
          ec2.InstanceType.of(ec2.InstanceClass.M5, ec2.InstanceSize.LARGE),
        ],
        maxvCpus: 4,
        minvCpus: 0,
        spot: true,
      },
    );

    // ─── Batch Job Queue ───────────────────────────────────────────────────────
    this.jobQueue = new batch.JobQueue(this, 'JobQueue', {
      priority: 1,
      computeEnvironments: [
        {
          computeEnvironment: this.computeEnvironment,
          order: 1,
        },
      ],
    });

    // Head Job Role: Batch permissions (scoped to this queue)
    this.headJobRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'BatchJobManagement',
        actions: [
          'batch:SubmitJob',
          'batch:DescribeJobs',
          'batch:ListJobs',
          'batch:CancelJob',
          'batch:TerminateJob',
        ],
        resources: ['*'], // Batch actions require * for DescribeJobs/ListJobs
      }),
    );

    // ─── Batch Job Definition ──────────────────────────────────────────────────
    this.jobDefinition = new batch.EcsJobDefinition(this, 'HeadJobDef', {
      container: new batch.EcsEc2ContainerDefinition(this, 'HeadContainer', {
        image: ecs.ContainerImage.fromRegistry('nextflow/nextflow:26.04.6'),
        cpu: 2,
        memory: cdk.Size.mebibytes(4096),
        jobRole: this.headJobRole,
        environment: {
          NXF_WORK: `s3://${this.bucket.bucketName}/work/`,
          NXF_OUTPUT: `s3://${this.bucket.bucketName}/output/`,
          NXF_EXECUTOR: 'awsbatch',
          NXF_QUEUE: this.jobQueue.jobQueueName,
        },
        logging: ecs.LogDrivers.awsLogs({
          logGroup: this.logGroup,
          streamPrefix: 'nextflow',
        }),
      }),
      timeout: cdk.Duration.seconds(7200),
      retryAttempts: 1,
    });

    // ─── CloudFormation Outputs ────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'S3BucketName', {
      value: this.bucket.bucketName,
      description: 'S3 bucket for pipeline input data, output results, and Nextflow work directory',
    });

    new cdk.CfnOutput(this, 'BatchJobQueueArn', {
      value: this.jobQueue.jobQueueArn,
      description: 'AWS Batch job queue ARN for submitting pipeline jobs',
    });

    new cdk.CfnOutput(this, 'BatchJobDefinitionArn', {
      value: this.jobDefinition.jobDefinitionArn,
      description: 'AWS Batch job definition ARN for the Nextflow head job container',
    });

    new cdk.CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
      description: 'VPC ID containing all pipeline compute resources',
    });

    new cdk.CfnOutput(this, 'LogGroupName', {
      value: this.logGroup.logGroupName,
      description: 'CloudWatch Log Group for pipeline execution logs',
    });

    new cdk.CfnOutput(this, 'SampleSubmitCommand', {
      value: [
        'aws batch submit-job',
        `--job-name "genomechronicler-run"`,
        `--job-queue ${this.jobQueue.jobQueueArn}`,
        `--job-definition ${this.jobDefinition.jobDefinitionArn}`,
        '--container-overrides \'{"command":["nextflow","run","https://github.com/afonsoguerra/GenomeChronicler26-nextflow",',
        '"-r","feat/aws-cdk-deployment",',
        `"--input","s3://${this.bucket.bucketName}/input/samplesheet.csv",`,
        `"--outdir","s3://${this.bucket.bucketName}/output/",`,
        '"--gc_container","ghcr.io/pgp-uk/genomechronicler:latest",',
        '"-profile","docker,test",',
        `"-work-dir","s3://${this.bucket.bucketName}/work/"]}\'`,
      ].join(' '),
      description: 'Example AWS CLI command to submit a pipeline run (replace samplesheet path as needed)',
    });
  }
}
