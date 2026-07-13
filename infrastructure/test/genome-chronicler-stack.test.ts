import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { GenomeChroniclerStack } from '../lib/genome-chronicler-stack';

describe('GenomeChroniclerStack', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App({
      context: { bucketPrefix: 'genomechronicler-test' },
    });
    const stack = new GenomeChroniclerStack(app, 'TestStack', {
      bucketPrefix: 'genomechronicler-test',
    });
    template = Template.fromStack(stack);
  });

  // ─── VPC Tests ─────────────────────────────────────────────────────────────

  test('VPC is provisioned with private and public subnets', () => {
    template.resourceCountIs('AWS::EC2::VPC', 1);
    template.hasResourceProperties('AWS::EC2::VPC', {
      CidrBlock: '10.0.0.0/16',
    });
  });

  test('Exactly 1 NAT Gateway is provisioned', () => {
    template.resourceCountIs('AWS::EC2::NatGateway', 1);
  });

  // ─── S3 Bucket Tests ───────────────────────────────────────────────────────

  test('S3 bucket has versioning enabled', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      VersioningConfiguration: { Status: 'Enabled' },
    });
  });

  test('S3 bucket has SSE-S3 encryption', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256',
            },
          },
        ],
      },
    });
  });

  test('S3 bucket blocks all public access', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('S3 bucket has lifecycle rules for work/ prefix (7 day expiration)', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Id: 'ExpireWorkDir',
            Prefix: 'work/',
            ExpirationInDays: 7,
            Status: 'Enabled',
          }),
        ]),
      },
    });
  });

  test('S3 bucket has RETAIN deletion policy', () => {
    template.hasResource('AWS::S3::Bucket', {
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  // ─── Batch Compute Environment Tests ───────────────────────────────────────

  test('Batch Compute Environment is EC2 SPOT with maxvCpus=4', () => {
    template.hasResourceProperties('AWS::Batch::ComputeEnvironment', {
      Type: 'MANAGED',
      ComputeResources: Match.objectLike({
        Type: 'SPOT',
        MaxvCpus: 4,
        MinvCpus: 0,
      }),
    });
  });

  // ─── Batch Job Queue Tests ─────────────────────────────────────────────────

  test('Batch Job Queue has priority 1', () => {
    template.hasResourceProperties('AWS::Batch::JobQueue', {
      Priority: 1,
    });
  });

  // ─── Batch Job Definition Tests ────────────────────────────────────────────

  test('Job Definition has nextflow/nextflow:latest container image', () => {
    template.hasResourceProperties('AWS::Batch::JobDefinition', {
      ContainerProperties: Match.objectLike({
        Image: 'nextflow/nextflow:latest',
      }),
    });
  });

  test('Job Definition has 2 vCPUs and 4096 MB memory', () => {
    template.hasResourceProperties('AWS::Batch::JobDefinition', {
      ContainerProperties: Match.objectLike({
        ResourceRequirements: Match.arrayWith([
          { Type: 'VCPU', Value: '2' },
          { Type: 'MEMORY', Value: '4096' },
        ]),
      }),
    });
  });

  test('Job Definition has 7200 second timeout', () => {
    template.hasResourceProperties('AWS::Batch::JobDefinition', {
      Timeout: { AttemptDurationSeconds: 7200 },
    });
  });

  test('Job Definition has retry attempts set to 1', () => {
    template.hasResourceProperties('AWS::Batch::JobDefinition', {
      RetryStrategy: { Attempts: 1 },
    });
  });

  // ─── CloudWatch Log Group Tests ────────────────────────────────────────────

  test('CloudWatch Log Group has 14-day retention', () => {
    template.hasResourceProperties('AWS::Logs::LogGroup', {
      LogGroupName: '/genomechronicler-test/batch',
      RetentionInDays: 14,
    });
  });

  // ─── CloudFormation Outputs Tests ──────────────────────────────────────────

  test('Stack has all required outputs', () => {
    const outputs = template.toJSON().Outputs;
    expect(outputs).toBeDefined();

    // Check output keys exist
    const outputKeys = Object.keys(outputs);
    expect(outputKeys.some((k) => k.includes('S3BucketName'))).toBe(true);
    expect(outputKeys.some((k) => k.includes('BatchJobQueueArn'))).toBe(true);
    expect(outputKeys.some((k) => k.includes('BatchJobDefinitionArn'))).toBe(true);
    expect(outputKeys.some((k) => k.includes('VpcId'))).toBe(true);
    expect(outputKeys.some((k) => k.includes('LogGroupName'))).toBe(true);
    expect(outputKeys.some((k) => k.includes('SampleSubmitCommand'))).toBe(true);
  });

  test('All outputs have descriptions', () => {
    const outputs = template.toJSON().Outputs;
    for (const [key, output] of Object.entries(outputs)) {
      expect((output as any).Description).toBeDefined();
      expect((output as any).Description.length).toBeGreaterThan(0);
    }
  });
});
